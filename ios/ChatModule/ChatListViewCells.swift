import AVFoundation
import CoreImage
import ImageIO
import LinkPresentation
import MediaPlayer
import UIKit

private let chatCellHoldDebugLogs = false
private let chatCellReactionDebugLogs = false
private let chatCellMediaDebugLogs = false
private let chatCellInlineVideoDebugLogs = false
private let chatCellBubbleFlickerDebugLogs = false
private let chatMediaImageCache: NSCache<NSString, UIImage> = {
  let cache = NSCache<NSString, UIImage>()
  cache.countLimit = 96
  cache.totalCostLimit = 48 * 1024 * 1024
  return cache
}()
private let chatMediaNaturalSizeCache = NSCache<NSString, NSValue>()
private let chatMediaAudioAvailabilityCache = NSCache<NSString, NSNumber>()
/// Memo entries whose size is the blur thumb's shape, not the media's pixels.
private let chatMediaThumbDerivedSizeKeys = NSCache<NSString, NSNumber>()

/// Bytes a decoded image holds (every frame of an animated one), for the cache's cost limit.
func chatMediaImageCost(_ image: UIImage) -> Int {
  (image.images ?? [image]).reduce(0) { total, frame in
    if let cgImage = frame.cgImage { return total + cgImage.bytesPerRow * cgImage.height }
    let pixels = frame.size.width * frame.size.height * frame.scale * frame.scale
    return total + Int(pixels * 4.0)
  }
}

/// Every insert carries its byte cost so `totalCostLimit` evicts LRU under pressure.
private func chatMediaImageCacheStore(_ image: UIImage, forKey key: String) {
  chatMediaImageCache.setObject(image, forKey: key as NSString, cost: chatMediaImageCost(image))
}

/// BubbleShape still carries the legacy 18pt geometry from the row payload. Rebase each
/// corner onto the appearance radius so grouped corners retain their relative tightening.
private func chatAppearanceBubbleShape(
  _ shape: BubbleShape,
  appearance: ChatListAppearance
) -> BubbleShape {
  let legacyPrimaryRadius: CGFloat = 18.0
  let primaryRadius = max(0.0, appearance.messageCornerRadius)
  func resolvedRadius(_ legacyRadius: CGFloat) -> CGFloat {
    guard legacyRadius > 0.0 else { return 0.0 }
    let proportion = min(1.0, legacyRadius / legacyPrimaryRadius)
    return min(primaryRadius, max(min(2.0, primaryRadius), primaryRadius * proportion))
  }
  return BubbleShape(
    isMe: shape.isMe,
    showTail: shape.showTail,
    borderTopLeftRadius: resolvedRadius(shape.borderTopLeftRadius),
    borderTopRightRadius: resolvedRadius(shape.borderTopRightRadius),
    borderBottomLeftRadius: resolvedRadius(shape.borderBottomLeftRadius),
    borderBottomRightRadius: resolvedRadius(shape.borderBottomRightRadius)
  )
}

/// Drop decoded chat media under memory pressure (called from AppDelegate).
func chatMediaImageCachePurgeForMemoryWarning() {
  chatMediaImageCache.removeAllObjects()
  chatMediaNaturalSizeCache.removeAllObjects()
  chatMediaThumbDerivedSizeKeys.removeAllObjects()
  chatMediaAudioAvailabilityCache.removeAllObjects()
}

// MARK: - Disk-backed image cache

private let chatMediaDiskCacheQueue = DispatchQueue(label: "chat.media.disk-cache", qos: .utility)
/// Keyed on the RAW url, deliberately — unlike the caches, which are keyed on stable identity.
/// A signed link that expired is a fact about that link, not about the media: when the server
/// hands us a freshly signed url for the same object it deserves a fresh attempt, and keying
/// this on identity would have made one expiry poison the photo for the rest of the session.
private var chatMediaFailedURLs = Set<String>()
private var chatMediaRetryCount: [String: Int] = [:]
private let chatMediaMaxRetries = 3
private let chatMediaVideoExtensions: Set<String> = [
  "mp4", "mov", "m4v", "avi", "mkv", "webm",
]

func chatStableCacheHash(_ value: String) -> String {
  var hash: UInt64 = 14_695_981_039_346_656_037
  for byte in value.utf8 {
    hash ^= UInt64(byte)
    hash = hash &* 1_099_511_628_211
  }
  return String(format: "%016llx", hash)
}

/// The `localMediaUrl` recorded when a message was sent, but ONLY if that file is still on
/// disk — otherwise nil, so the caller falls through to the remote url and finds the durable
/// vault copy. The recorded path dies two ordinary ways: the data-container UUID changes on
/// every reinstall (contents survive, the path does not — hence the relocation), and the picked
/// file lives in `Library/Caches`, which iOS reclaims whenever it likes. Handing back a dead
/// path is worse than having none: a file URL makes the bubble report "no download needed", so
/// it plays nothing and never consults the vault copy keyed by the REMOTE url.
func chatExistingLocalMediaPath(_ raw: String?) -> String? {
  guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
  else { return nil }
  let parsed: URL
  if let url = URL(string: trimmed), url.isFileURL {
    parsed = url
  } else if trimmed.hasPrefix("/") {
    parsed = URL(fileURLWithPath: trimmed)
  } else {
    return nil
  }
  let relocated = ChatListView.relocatedToCurrentContainer(parsed)
  return FileManager.default.fileExists(atPath: relocated.path) ? relocated.path : nil
}

/// Durable on-disk root for chat media (NOT Caches — iOS purges Caches under pressure,
/// which forced re-download after reopen for voice/music/images the user already had).
func vibeDurableMediaCacheRoot() -> URL {
  let fm = FileManager.default
  let base =
    fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
    ?? fm.temporaryDirectory
  let root = base.appendingPathComponent("VibeMediaCache", isDirectory: true)
  try? fm.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

/// Stable identity for remote media cache slots. Strips volatile query/fragment and
/// collapses `/api/music/stream/<id>` to `musicstream:<id>` so reopen never MISS-es
/// a file that was seeded/downloaded under a slightly different URL.
func chatStableRemoteMediaIdentity(_ url: URL) -> String {
  if let videoId = ChatMusicStreamResolver.videoId(fromBackendStreamURL: url) {
    return "musicstream:\(videoId)"
  }
  var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
  comps?.query = nil
  comps?.fragment = nil
  let host = (comps?.host ?? "").lowercased()
  let path = comps?.path ?? url.path
  if !host.isEmpty {
    return host + path
  }
  return comps?.string ?? url.absoluteString
}


/// Strips tracking query params from Giphy (and similar CDN) URLs so the same
/// media content always maps to the same cache key regardless of session tokens.
private func chatMediaNormalizedKey(_ urlString: String) -> String {
  guard var comps = URLComponents(string: urlString),
    let host = comps.host?.lowercased(),
    host.contains("giphy.com")
  else { return urlString }
  // Remove Giphy tracking params — content is identified by path alone
  let trackingParams: Set<String> = ["cid", "rid", "ct", "ep", "r"]
  comps.queryItems = comps.queryItems?.filter { !trackingParams.contains($0.name) }
  if comps.queryItems?.isEmpty == true { comps.queryItems = nil }
  return comps.string ?? urlString
}

/// The address of a piece of chat media — for the in-memory cache and for the vault alike.
///
/// This used to be the URL *including* its query, which meant a re-signed link
/// (`?exp=…&sig=…`) produced a brand-new key for bytes already sitting on disk: every reopen
/// missed both caches, re-downloaded the photo, and faded it in late. Identity now comes from
/// `VibeMediaVault` — the same stable identity voice notes and documents were already keyed on,
/// so a photo downloaded in a chat is also found by home, profile, and the cache screen.
private func chatMediaCacheKey(_ urlString: String, mediaKey: String?) -> String {
  VibeMediaVault.identity(rawURL: urlString, mediaKey: mediaKey)
}

/// Vault identity of the row's REMOTE media, or nil while it only names a local file.
private func chatMediaRemoteIdentity(_ row: ChatListRow) -> String? {
  guard let raw = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
    let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
    scheme == "http" || scheme == "https"
  else { return nil }
  return VibeMediaVault.identity(rawURL: raw, mediaKey: nil)
}

/// Same bytes unless both rows name a remote and the remotes differ.
private func chatMediaRowsShareRemoteIdentity(_ a: ChatListRow, _ b: ChatListRow) -> Bool {
  guard let identityA = chatMediaRemoteIdentity(a), let identityB = chatMediaRemoteIdentity(b)
  else { return true }
  return identityA == identityB
}

/// The pre-vault key: the URL with its query intact. Kept only so a file an older build already
/// downloaded can still be found once, and moved into the vault under its stable identity,
/// instead of being re-fetched from an origin that may no longer have it.
private func chatMediaLegacyCacheKey(_ urlString: String, mediaKey: String?) -> String {
  let normalized = chatMediaNormalizedKey(urlString)
  let trimmedKey = mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  guard !trimmedKey.isEmpty else { return normalized }
  return normalized + "|k:" + trimmedKey
}

private func chatMediaDiskCacheKey(_ urlString: String) -> String {
  let normalized = chatMediaNormalizedKey(urlString)
  // Preserve extension for correct UIImage decoding
  let ext = (urlString as NSString).pathExtension.lowercased()
  let suffix = ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(ext) ? ".\(ext)" : ".img"
  return "v3-" + chatStableCacheHash(normalized) + suffix
}

/// Where an older build would have written this key. Consulted only on a vault miss.
private func chatMediaLegacyDiskCandidates(_ legacyKey: String) -> [URL] {
  let name = chatMediaDiskCacheKey(legacyKey)
  return VibeMediaVault.shared.externalDirectories(for: .image).map {
    $0.appendingPathComponent(name, isDirectory: false)
  }
}

/// A decodable extension for the stored file, or `img` when the key carries none. The vault
/// sanitises what it is handed, so anything ambiguous must be resolved to `img` here rather
/// than letting a fragment of a media key become a file extension.
private func chatMediaStoredFileExtension(forKey key: String) -> String {
  let ext = (key as NSString).pathExtension.lowercased()
  return ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(ext) ? ext : "img"
}

private func chatMediaShouldAnimate(urlString: String, messageType: String? = nil) -> Bool {
  if messageType == "gif" {
    return true
  }
  let pathExtension: String
  if let url = URL(string: urlString), !url.pathExtension.isEmpty {
    pathExtension = url.pathExtension.lowercased()
  } else {
    pathExtension = (urlString as NSString).pathExtension.lowercased()
  }
  return pathExtension == "gif"
}

private func chatMediaAnimatedFrameDuration(
  at index: Int, source: CGImageSource
) -> TimeInterval {
  guard
    let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
    let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
  else {
    return 0.1
  }

  let unclampedDelay = gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? TimeInterval
  let delay = gifProperties[kCGImagePropertyGIFDelayTime] as? TimeInterval
  let frameDuration = unclampedDelay ?? delay ?? 0.1
  return frameDuration < 0.011 ? 0.1 : frameDuration
}

/// Decode bounds: a bubble never shows more than the screen, and a GIF keeps every frame alive.
private let chatMediaDefaultDecodeMaxPixelSize = 1600
private let chatMediaAnimatedMaxFrames = 40
private let chatMediaAnimatedMaxPixelSize = 480

private var chatMediaBubbleMaxPixelSizeMemo = 0

/// Longest side, in pixels, a bubble can ever display. Never below 512. Off main it answers
/// from the last main-thread value, so UIScreen is only touched where UIKit allows.
func chatMediaBubbleDecodeMaxPixelSize(screen: UIScreen? = nil) -> Int {
  guard Thread.isMainThread else {
    return chatMediaBubbleMaxPixelSizeMemo > 0 ? chatMediaBubbleMaxPixelSizeMemo : 1290
  }
  let screen = screen ?? UIScreen.main
  let longest = max(screen.bounds.width, 380.0) * max(1.0, screen.scale)
  let value = max(512, Int(longest.rounded(.up)))
  chatMediaBubbleMaxPixelSizeMemo = value
  return value
}

private func chatMediaThumbnailOptions(maxPixelSize: Int) -> CFDictionary {
  let options: [CFString: Any] = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceShouldCacheImmediately: true,
    kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
  ]
  return options as CFDictionary
}

/// One frame, at most `maxPixelSize` on its longest side, display-ready. The UIImage keeps the
/// source's point size, so natural-size reporting does not change with the downsample.
private func chatMediaDisplayReadyFrame(
  source: CGImageSource, index: Int, maxPixelSize: Int
) -> UIImage? {
  guard
    let cgImage = CGImageSourceCreateThumbnailAtIndex(
      source, index, chatMediaThumbnailOptions(maxPixelSize: maxPixelSize))
  else { return nil }
  var scale: CGFloat = 1.0
  if let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
    let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
    let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
    width > 0.0, height > 0.0
  {
    let sourceLongest = max(width, height)
    let decodedLongest = Double(max(cgImage.width, cgImage.height))
    if decodedLongest > 0.0, sourceLongest > decodedLongest {
      scale = CGFloat(decodedLongest / sourceLongest)
    }
  }
  let image = UIImage(cgImage: cgImage, scale: scale, orientation: .up)
  guard let prepared = image.preparingForDisplay() else { return image }
  if abs(prepared.scale - scale) < 0.001 { return prepared }
  guard let preparedCG = prepared.cgImage else { return prepared }
  return UIImage(cgImage: preparedCG, scale: scale, orientation: .up)
}

/// Frames capped and downsampled; the total duration still covers every source frame.
private func chatMediaAnimatedImage(from source: CGImageSource, maxPixelSize: Int) -> UIImage? {
  let frameCount = CGImageSourceGetCount(source)
  guard frameCount > 1 else { return nil }
  let stride = max(
    1, Int((Double(frameCount) / Double(chatMediaAnimatedMaxFrames)).rounded(.up)))
  let frameMax = min(maxPixelSize, chatMediaAnimatedMaxPixelSize)
  var frames: [UIImage] = []
  frames.reserveCapacity(min(frameCount, chatMediaAnimatedMaxFrames + 1))
  var totalDuration: TimeInterval = 0.0
  for index in 0..<frameCount {
    totalDuration += chatMediaAnimatedFrameDuration(at: index, source: source)
    guard index % stride == 0,
      let frame = chatMediaDisplayReadyFrame(
        source: source, index: index, maxPixelSize: frameMax)
    else { continue }
    frames.append(frame)
  }
  guard !frames.isEmpty else { return nil }
  return UIImage.animatedImage(with: frames, duration: max(totalDuration, 0.1))
}

private func chatCellDebugLog(_ enabled: Bool, _ format: String, _ args: CVarArg...) {
  guard enabled else { return }
  withVaList(args) { pointer in
    NSLogv(format, pointer)
  }
}

/// Animated-aware decode for callers outside this file (GIF recents).
func chatMediaDecodedImagePublic(from data: Data, shouldAnimate: Bool) -> UIImage? {
  chatMediaDecodeImageCore(
    from: data, shouldAnimate: shouldAnimate, maxPixelSize: chatMediaDefaultDecodeMaxPixelSize)
}

/// The one decode funnel for bubble media. Off main only: it decodes and prepares pixels.
private func chatMediaDecodedImage(
  from data: Data, shouldAnimate: Bool, maxPixelSize: Int = chatMediaDefaultDecodeMaxPixelSize
) -> UIImage? {
  #if DEBUG
    dispatchPrecondition(condition: .notOnQueue(.main))
  #endif
  return chatMediaDecodeImageCore(
    from: data, shouldAnimate: shouldAnimate, maxPixelSize: maxPixelSize)
}

private func chatMediaDecodeImageCore(
  from data: Data, shouldAnimate: Bool, maxPixelSize: Int
) -> UIImage? {
  let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
  guard
    let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
    CGImageSourceGetCount(source) > 0
  else {
    guard let fallback = UIImage(data: data) else { return nil }
    return fallback.preparingForDisplay() ?? fallback
  }
  if shouldAnimate,
    let animated = chatMediaAnimatedImage(from: source, maxPixelSize: maxPixelSize)
  {
    return animated
  }
  return chatMediaDisplayReadyFrame(source: source, index: 0, maxPixelSize: maxPixelSize)
}

private func chatMediaImage(fromBase64 value: String?) -> UIImage? {
  chatMediaImageFromBase64Public(value)
}

/// Shared base64 → UIImage decode (used by list cells + native image open).
func chatMediaImageFromBase64Public(_ value: String?) -> UIImage? {
  guard let value else { return nil }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  let payload: String = {
    if let commaIndex = trimmed.firstIndex(of: ","),
      trimmed[..<commaIndex].contains("base64")
    {
      return String(trimmed[trimmed.index(after: commaIndex)...])
    }
    return trimmed
  }()
  guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else {
    return nil
  }
  return UIImage(data: data)
}

/// Pixel quality ladder for media bubbles. Thumbs never overwrite full media.
enum ChatMediaPreviewQuality: Int {
  case none = 0
  case microThumb = 1
  case full = 2
}

/// Telegram-style durable micro-thumb: ~64px longest side, JPEG ~0.5, typically ≤4KB.
/// Sender generates; server keeps `thumbnailBase64` in metadata (sealed blobs stay stripped).
private let chatMicroThumbMaxDimension: CGFloat = 64.0
private let chatMicroThumbJPEGQuality: CGFloat = 0.52
private let chatMicroThumbDecodedCache = NSCache<NSString, UIImage>()

/// Encode a tiny durable preview for wire + optimistic paint.
func chatMicroThumbnailJPEGBase64(
  from image: UIImage,
  maxDimension: CGFloat = chatMicroThumbMaxDimension
) -> String? {
  let size = image.size
  guard size.width > 0.5, size.height > 0.5 else { return nil }
  let longest = max(size.width, size.height)
  let scale = min(1.0, maxDimension / longest)
  let target = CGSize(
    width: max(1.0, floor(size.width * scale)),
    height: max(1.0, floor(size.height * scale))
  )
  let format = UIGraphicsImageRendererFormat.default()
  format.scale = 1.0
  format.opaque = true
  let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
    image.draw(in: CGRect(origin: .zero, size: target))
  }
  guard let jpeg = rendered.jpegData(compressionQuality: chatMicroThumbJPEGQuality) else {
    return nil
  }
  return jpeg.base64EncodedString()
}

/// Encode the same micro-thumb straight from a file, without ever decoding the
/// full-resolution image.
///
/// `UIImage(contentsOfFile:)` followed by `draw(in:)` materializes the entire bitmap:
/// a 12MP photo costs tens of megabytes and ~100ms of main-thread decode to produce a
/// 64px thumbnail that is then thrown away. ImageIO decodes at the reduced size
/// directly, so a multi-image send stops paying a full decode per picture — that pass
/// was measured at 0.56s of blocked main thread on a single send.
///
/// `kCGImageSourceCreateThumbnailWithTransform` is not optional. Without it ImageIO
/// returns the raw pixels and ignores the EXIF orientation, so every photo taken in
/// portrait would ship a sideways thumbnail — orientation is the one thing
/// `UIImage(contentsOfFile:)` was handling for free, and it has to be asked for here.
///
/// Falls back to the decoded-image path for anything ImageIO cannot open, so a format
/// it does not understand still produces a thumbnail rather than none.
func chatMicroThumbnailJPEGBase64(
  contentsOf fileURL: URL,
  maxDimension: CGFloat = chatMicroThumbMaxDimension
) -> String? {
  func decodedFallback() -> String? {
    UIImage(contentsOfFile: fileURL.path).flatMap {
      chatMicroThumbnailJPEGBase64(from: $0, maxDimension: maxDimension)
    }
  }
  let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
  guard
    let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions as CFDictionary)
  else { return decodedFallback() }
  let thumbnailOptions: [CFString: Any] = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceShouldCacheImmediately: true,
    kCGImageSourceThumbnailMaxPixelSize: Int(max(1.0, maxDimension)),
  ]
  guard
    let thumbnail = CGImageSourceCreateThumbnailAtIndex(
      source, 0, thumbnailOptions as CFDictionary),
    let jpeg = UIImage(cgImage: thumbnail)
      .jpegData(compressionQuality: chatMicroThumbJPEGQuality)
  else { return decodedFallback() }
  return jpeg.base64EncodedString()
}

/// Shared context for the placeholder blur. Building a `CIContext` is the expensive part
/// of Core Image — tens of milliseconds — while the filter itself, on an image this
/// small, is not. One global, created on first use.
private let chatMicroThumbBlurContext = CIContext(options: [.useSoftwareRenderer: false])

/// Turn a micro-thumb into the soft placeholder, rather than a small image stretched big.
///
/// A 64px thumb spread across a ~300pt bubble is a 12x upscale, and at that factor the
/// JPEG's 8x8 blocks become visible squares with hard edges between them. That is what
/// reads as *broken resolution* instead of an intentional preview — the eye recognises
/// block edges and interpolation seams as damage, not as blur. A Gaussian destroys
/// exactly those artifacts while keeping the broad colour layout that makes a placeholder
/// worth showing at all, which is the difference between our plate and Telegram's.
///
/// Baked into the cached bitmap on purpose, NOT applied as a live `UIVisualEffectView`
/// over each cell. A visual-effect view is a per-frame GPU cost on every visible media
/// cell, and it is a frosted *material* — it desaturates and lifts everything toward the
/// material colour — where this needs a plain blur of the image's own colours.
private func chatBlurredMicroThumbnail(_ image: UIImage) -> UIImage? {
  let size = image.size
  let longest = max(size.width, size.height)
  guard longest > 0.5 else { return nil }
  // Upscale before blur so JPEG 8x8 blocks don't become a grate. Keep the blur light.
  let scale = max(1.0, 240.0 / longest)
  let target = CGSize(
    width: max(1.0, (size.width * scale).rounded()),
    height: max(1.0, (size.height * scale).rounded())
  )
  let format = UIGraphicsImageRendererFormat.default()
  format.scale = 1.0
  format.opaque = true
  let upscaled = UIGraphicsImageRenderer(size: target, format: format).image { context in
    context.cgContext.interpolationQuality = .high
    image.draw(in: CGRect(origin: .zero, size: target))
  }
  guard let upscaledCG = upscaled.cgImage else { return nil }
  let input = CIImage(cgImage: upscaledCG)
  guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
  // Clamped to extent first: a Gaussian samples beyond the edges, and against a finite
  // input those samples come back transparent — which fades the border and gives the
  // placeholder a washed-out frame instead of a full-bleed one.
  filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
  filter.setValue(max(1.0, max(target.width, target.height) * 0.025), forKey: kCIInputRadiusKey)
  guard let output = filter.outputImage,
    let rendered = chatMicroThumbBlurContext.createCGImage(output, from: input.extent)
  else { return nil }
  return UIImage(cgImage: rendered)
}

/// Sync decode of micro-thumb for first paint. Clamps oversized legacy thumbs so
/// main-thread configure never stalls on a full-res base64 blob.
///
/// Returns the SHARP thumb — the blur is a Core Image pass and belongs off main; ask for
/// it with ``chatRequestMicroThumbBlur``.
func chatDecodedMicroThumbnail(fromBase64 value: String?, cacheKey: String?) -> UIImage? {
  if let cacheKey,
    let hit = chatMicroThumbDecodedCache.object(forKey: cacheKey as NSString)
  {
    return hit
  }
  guard let image = chatMediaImageFromBase64Public(value) else { return nil }
  let size = image.size
  let clampDim: CGFloat = 128.0
  let clamped: UIImage
  if max(size.width, size.height) > clampDim + 0.5 {
    let scale = clampDim / max(size.width, size.height)
    let target = CGSize(
      width: max(1.0, floor(size.width * scale)),
      height: max(1.0, floor(size.height * scale))
    )
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1.0
    format.opaque = true
    clamped = UIGraphicsImageRenderer(size: target, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }
  } else {
    clamped = image
  }
  if let cacheKey {
    chatMicroThumbDecodedCache.setObject(clamped, forKey: cacheKey as NSString)
  }
  return clamped
}

private let chatMicroThumbBlurQueue = DispatchQueue(
  label: "vibe.microthumb.blur", qos: .userInitiated)
private let chatMicroThumbBlurLock = NSLock()
private var chatMicroThumbBlurInFlight = Set<String>()

/// Blurs a sharp micro-thumb off main, once per key, and calls back on main.
///
/// Ran inline in `cellForItemAt` before: a device trace charged it a 0.56s main-thread
/// hang during a chat open. The result replaces the sharp thumb in both thumb caches, so
/// every later configure reads the blurred one straight from memory.
func chatRequestMicroThumbBlur(
  sharp: UIImage,
  cacheKey: String,
  completion: @escaping (UIImage) -> Void
) {
  chatMicroThumbBlurLock.lock()
  let alreadyRunning = !chatMicroThumbBlurInFlight.insert(cacheKey).inserted
  chatMicroThumbBlurLock.unlock()
  guard !alreadyRunning else { return }
  chatMicroThumbBlurQueue.async {
    let blurred = chatBlurredMicroThumbnail(sharp)
    chatMicroThumbBlurLock.lock()
    chatMicroThumbBlurInFlight.remove(cacheKey)
    chatMicroThumbBlurLock.unlock()
    // No Core Image result — the sharp thumb stays. A blocky placeholder still beats the
    // empty plate this path exists to avoid.
    guard let blurred else { return }
    chatMicroThumbDecodedCache.setObject(blurred, forKey: cacheKey as NSString)
    DispatchQueue.main.async { completion(blurred) }
  }
}


private func chatMediaResolvedVideoExtension(
  urlString: String,
  fileName: String?,
  messageType: String
) -> String {
  let candidates: [String] = [
    fileName ?? "",
    (URL(string: urlString)?.pathExtension ?? ""),
    (urlString as NSString).pathExtension,
  ]
  for candidate in candidates {
    let ext = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ".", with: "")
      .lowercased()
    if chatMediaVideoExtensions.contains(ext) {
      return ext
    }
  }
  return messageType == "video" ? "mp4" : "mov"
}

private func chatMediaHeaderSummary(from data: Data) -> String {
  guard !data.isEmpty else { return "none" }
  let bytes = [UInt8](data.prefix(16))
  let hex = bytes.map { String(format: "%02x", $0) }.joined()
  var brand = "-"
  if data.count >= 12 {
    let brandData = data.subdata(in: 8..<12)
    brand = String(data: brandData, encoding: .ascii) ?? "-"
  }
  return "hex=\(hex) brand=\(brand)"
}

private func chatMediaFileHeaderSummary(at path: String) -> String {
  guard let handle = FileHandle(forReadingAtPath: path) else { return "none" }
  defer { try? handle.close() }
  let data = (try? handle.read(upToCount: 16)) ?? Data()
  return chatMediaHeaderSummary(from: data)
}

/// The poster JPEG for a video identity has its own slot beside the bytes.
private func chatMediaPosterIdentity(_ identity: String) -> String { identity + "#poster" }

/// A poster this device already extracted, decoded at the bubble's size. Off main only.
private func chatMediaStoredVideoPoster(identity: String, maxPixelSize: Int) -> UIImage? {
  guard
    let url = VibeMediaVault.shared.cachedURL(
      for: chatMediaPosterIdentity(identity), kind: .videoPreview),
    let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
  else { return nil }
  return chatMediaDecodedImage(from: data, shouldAnimate: false, maxPixelSize: maxPixelSize)
}

/// Extracts one frame, persists it as JPEG so extraction happens once per device, and
/// returns it display-ready. Off main only.
private func chatMediaExtractedVideoPoster(
  fileURL: URL, identity: String?, maxPixelSize: Int
) -> UIImage? {
  let extractSide = CGFloat(max(1024, maxPixelSize))
  guard
    let cgImage = chatMediaCopyVideoPreviewImage(
      from: AVURLAsset(url: fileURL), maxSize: CGSize(width: extractSide, height: extractSide))
  else { return nil }
  let frame = UIImage(cgImage: cgImage)
  if let identity, let jpeg = frame.jpegData(compressionQuality: 0.85) {
    VibeMediaVault.shared.store(
      jpeg, for: chatMediaPosterIdentity(identity), kind: .videoPreview, fileExtension: "jpg")
    if let decoded = chatMediaDecodedImage(
      from: jpeg, shouldAnimate: false, maxPixelSize: maxPixelSize)
    {
      return decoded
    }
  }
  return frame.preparingForDisplay() ?? frame
}

private func chatMediaVideoThumbnail(
  from data: Data,
  cacheKey: String,
  urlString: String,
  fileName: String?,
  messageType: String,
  maxPixelSize: Int
) -> UIImage? {
  if let poster = chatMediaStoredVideoPoster(identity: cacheKey, maxPixelSize: maxPixelSize) {
    return poster
  }
  let ext = chatMediaResolvedVideoExtension(
    urlString: urlString,
    fileName: fileName,
    messageType: messageType
  )
  // AVFoundation needs a real file to read a poster frame out of. Reuse the one already in the
  // vault instead of rewriting the whole video every time a poster is wanted.
  let vault = VibeMediaVault.shared
  let cached = vault.cachedURL(for: cacheKey, kind: .videoPreview)
  guard
    let fileURL = cached
      ?? vault.store(data, for: cacheKey, kind: .videoPreview, fileExtension: ext)
  else { return nil }
  if let poster = chatMediaExtractedVideoPoster(
    fileURL: fileURL, identity: cacheKey, maxPixelSize: maxPixelSize)
  {
    return poster
  }
  // A cached file that yields no frame is unusable — the one case where the vault drops a file
  // on its own. Write the bytes we were just handed and try once more.
  guard cached != nil else { return nil }
  vault.forget(cacheKey, kind: .videoPreview)
  guard let fresh = vault.store(data, for: cacheKey, kind: .videoPreview, fileExtension: ext)
  else { return nil }
  return chatMediaExtractedVideoPoster(
    fileURL: fresh, identity: cacheKey, maxPixelSize: maxPixelSize)
}

/// Off main only: `duration` and `copyCGImage` both block on the asset.
private func chatMediaCopyVideoPreviewImage(
  from asset: AVAsset,
  maxSize: CGSize
) -> CGImage? {
  #if DEBUG
    dispatchPrecondition(condition: .notOnQueue(.main))
  #endif
  let generator = AVAssetImageGenerator(asset: asset)
  generator.appliesPreferredTrackTransform = true
  generator.maximumSize = maxSize
  let rawCandidates: [Double] = [0.0, 0.12]
  let durationSeconds = CMTimeGetSeconds(asset.duration)
  let effectiveDuration = durationSeconds.isFinite ? max(0.0, durationSeconds) : 0.0
  let requestedSeconds = rawCandidates
    .filter { effectiveDuration <= 0.01 || $0 <= effectiveDuration }
  for seconds in requestedSeconds {
    do {
      return try generator.copyCGImage(
        at: CMTime(seconds: seconds, preferredTimescale: 600),
        actualTime: nil
      )
    } catch {
      continue
    }
  }
  return nil
}

private func chatMediaPreviewImage(
  from data: Data,
  shouldAnimate: Bool,
  cacheKey: String,
  urlString: String,
  fileName: String?,
  messageType: String,
  preferVideoPreview: Bool,
  maxPixelSize: Int = chatMediaDefaultDecodeMaxPixelSize
) -> UIImage? {
  if let image = chatMediaDecodedImage(
    from: data, shouldAnimate: shouldAnimate, maxPixelSize: maxPixelSize)
  {
    return image
  }
  guard preferVideoPreview else {
    return nil
  }
  return chatMediaVideoThumbnail(
    from: data,
    cacheKey: cacheKey,
    urlString: urlString,
    fileName: fileName,
    messageType: messageType,
    maxPixelSize: maxPixelSize
  )
}

/// Image or video file → display-ready image. Off main only; a video poster is persisted
/// under `posterIdentity` so the frame is extracted once per device.
private func chatMediaLoadImageFromFile(
  at path: String, shouldAnimate: Bool,
  maxPixelSize: Int = chatMediaDefaultDecodeMaxPixelSize,
  posterIdentity: String? = nil
) -> UIImage? {
  let isVideoFile = chatMediaVideoExtensions.contains(
    (path as NSString).pathExtension.lowercased())
  if isVideoFile, let posterIdentity,
    let poster = chatMediaStoredVideoPoster(identity: posterIdentity, maxPixelSize: maxPixelSize)
  {
    return poster
  }
  guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
  else {
    return nil
  }
  if !isVideoFile,
    let image = chatMediaDecodedImage(
      from: data, shouldAnimate: shouldAnimate, maxPixelSize: maxPixelSize)
  {
    return image
  }
  if let posterIdentity,
    let poster = chatMediaStoredVideoPoster(identity: posterIdentity, maxPixelSize: maxPixelSize)
  {
    return poster
  }
  return chatMediaExtractedVideoPoster(
    fileURL: URL(fileURLWithPath: path), identity: posterIdentity, maxPixelSize: maxPixelSize)
}

private func chatMediaDecryptedDataIfNeeded(_ data: Data, mediaKey: String?) -> Data? {
  ChatEngine.shared.decryptMediaDataIfNeeded(data, mediaKey: mediaKey)
}

func chatMediaDiskCacheSave(_ data: Data, forKey cacheKey: String) {
  chatMediaDiskCacheQueue.async {
    let vault = VibeMediaVault.shared
    guard !vault.contains(cacheKey, kind: .image) else { return }
    vault.store(
      data, for: cacheKey, kind: .image,
      fileExtension: chatMediaStoredFileExtension(forKey: cacheKey))
  }
}

/// Seed the remote-media disk cache with the just-uploaded local file so the sender
/// never re-downloads its own media after a restart/history reload (the echo row keeps
/// only the remote URL). Mirrors VoiceBubblePlaybackCoordinator.seedRemoteVoiceCacheFromLocal.
/// The key must match the remote-load path: chatMediaCacheKey(remoteURL, mediaKey:).
func chatMediaSeedRemoteCacheFromLocalFile(localURI: String, remoteURL: String, mediaKey: String?) {
  let trimmedRemote = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmedRemote.isEmpty else { return }
  let relocated = chatExistingLocalMediaPath(localURI)
  let path: String
  if let relocated {
    path = relocated
  } else if let parsed = URL(string: localURI), parsed.isFileURL {
    path = parsed.path
  } else {
    path = localURI
  }
  let exists = relocated != nil
  let attrs = try? FileManager.default.attributesOfItem(atPath: path)
  let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
  guard exists, bytes > 0, bytes <= 25 * 1024 * 1024 else {
    ChatMediaWatchdog.once(
      key: "seed-fail:\(trimmedRemote)",
      "seed-fail reason=local-missing exists=\(exists ? "Y" : "N") bytes=\(bytes) path=\(path) remote=\(trimmedRemote)"
    )
    return
  }
  let vault = VibeMediaVault.shared
  let keys = [chatMediaCacheKey(trimmedRemote, mediaKey: mediaKey)]
    + ((mediaKey?.isEmpty == false) ? [chatMediaCacheKey(trimmedRemote, mediaKey: nil)] : [])
  var seeded = false
  for cacheKey in keys where !vault.contains(cacheKey, kind: .image) {
    if vault.adopt(fileAt: URL(fileURLWithPath: path), for: cacheKey, kind: .image, move: false)
      != nil
    {
      seeded = true
    }
  }
  ChatMediaWatchdog.once(
    key: "seed:\(trimmedRemote)",
    "seed-outgoing ok=\(seeded ? "Y" : "N") bytes=\(bytes) remote=\(trimmedRemote) local=\(path)"
  )
}

/// On-disk file for this row: surviving local path (relocated to the current container), or
/// the vault copy keyed by remote URL — adopting the keyed legacy slot on a miss.
func chatOnDiskMediaFileURL(for row: ChatListRow) -> URL? {
  if let local = chatExistingLocalMediaPath(row.localMediaUrl) {
    return URL(fileURLWithPath: local)
  }
  guard let remote = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
    !remote.isEmpty
  else { return nil }
  let vault = VibeMediaVault.shared
  let key = VibeMediaVault.identity(rawURL: remote, mediaKey: row.mediaKey)
  let remoteURL = URL(string: remote).flatMap { $0.scheme == nil ? nil : $0 }
  for kind in [VibeMediaKind.image, .document] {
    if let url = vault.cachedURL(for: key, kind: kind) { return url }
    if let remoteURL,
      let adopted = vault.adoptLegacyKeyed(remoteURL: remoteURL, mediaKey: row.mediaKey, kind: kind)
    {
      return adopted
    }
  }
  return nil
}

/// Bytes for a media key, from disk only. `legacyRawKey` is the pre-vault key for the same
/// media; pass it wherever the raw URL is still in hand so an already-downloaded file is
/// adopted into the vault rather than re-fetched. `mediaKey` reaches the keyed legacy slot.
func chatMediaDiskCacheLoad(
  _ cacheKey: String, legacyRawKey: String? = nil, remoteURL: String? = nil,
  mediaKey: String? = nil
) -> Data? {
  let legacy = legacyRawKey.map(chatMediaLegacyDiskCandidates) ?? []
  let vault = VibeMediaVault.shared
  var fileURL = vault.cachedURL(for: cacheKey, kind: .image, legacyCandidates: legacy)
  if fileURL == nil, let remoteURL, let parsed = URL(string: remoteURL), parsed.scheme != nil {
    fileURL = vault.adoptLegacyKeyed(remoteURL: parsed, mediaKey: mediaKey, kind: .image)
  }
  guard let fileURL else { return nil }
  return try? Data(contentsOf: fileURL, options: [.mappedIfSafe])
}

// MARK: - Music album cover cache

/// Shared mem+disk cache key for a music album cover URL. Music rows carry the
/// cover as a remote URL (`ChatListRow.musicCoverURL`); we decode it once and reuse
/// the image across the chat bubble plate, the mini player banner, and the full player.
func chatMusicCoverCacheKey(_ url: String) -> String { "musiccover|\(url)" }

/// A music album cover already decoded IN MEMORY, if any. Mem-only, so it is safe to
/// call on layout / hot paths; disk and network warming happen in `chatLoadMusicCover`.
func chatCachedMusicCoverImage(for row: ChatListRow) -> UIImage? {
  guard let raw = row.musicCoverURL?.trimmingCharacters(in: .whitespacesAndNewlines),
    !raw.isEmpty
  else { return nil }
  return chatMediaImageCache.object(forKey: chatMusicCoverCacheKey(raw) as NSString)
}

/// Best static artwork for an audio/music row: a warm album cover beats an inline
/// base64 thumbnail (voice notes), which beats art recovered from the file's own tags,
/// which beats nothing. Synchronous / mem-only.
func chatMusicArtworkImage(for row: ChatListRow) -> UIImage? {
  if let cover = chatCachedMusicCoverImage(for: row) { return cover }
  if let thumb = chatMediaImage(fromBase64: row.thumbnailBase64) { return thumb }
  guard let messageId = row.messageId, !messageId.isEmpty else { return nil }
  return chatRecoveredAudioTags.artwork(for: messageId)
}

/// Cover art and artist read back out of the audio file itself.
///
/// A track whose tags never reached the server — Saved Messages sealed a payload without
/// `thumbnailBase64` until 2026-07-28 — still has the picture inside the mp3 sitting in the
/// vault. Recovering it there beats showing a blank plate forever for every message already
/// sent, and it costs one metadata parse per track per launch, off the main thread.
final class ChatRecoveredAudioTags {
  struct Tags {
    let artwork: UIImage?
    let artist: String?
  }

  private let cache = NSCache<NSString, AnyObject>()
  private var attempted = Set<String>()
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "vibe.chat.audio-tags", qos: .utility)

  func artwork(for messageId: String) -> UIImage? {
    (cache.object(forKey: messageId as NSString) as? Box)?.tags.artwork
  }

  func artist(for messageId: String) -> String? {
    (cache.object(forKey: messageId as NSString) as? Box)?.tags.artist
  }

  /// Parses once per message per launch. `completion` runs on the main thread and only when
  /// something was actually recovered, so a tagless file never triggers a repaint.
  func recover(messageId: String, fileURL: URL, completion: @escaping (Tags) -> Void) {
    if let box = cache.object(forKey: messageId as NSString) as? Box {
      if box.tags.artwork != nil || box.tags.artist != nil {
        DispatchQueue.main.async { completion(box.tags) }
      }
      return
    }
    lock.lock()
    let alreadyRunning = attempted.contains(messageId)
    if !alreadyRunning { attempted.insert(messageId) }
    lock.unlock()
    guard !alreadyRunning else { return }

    queue.async { [weak self] in
      guard let self else { return }
      let metadata = AVURLAsset(url: fileURL).commonMetadata
      func value(_ key: String) -> AVMetadataItem? {
        metadata.first { $0.commonKey?.rawValue.lowercased() == key }
      }
      let artworkData = value("artwork")?.dataValue ?? value("artwork")?.value as? Data
      let artwork = artworkData.flatMap { UIImage(data: $0) }
      let artist = value("artist")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
      let tags = Tags(artwork: artwork, artist: (artist?.isEmpty ?? true) ? nil : artist)
      self.cache.setObject(Box(tags: tags), forKey: messageId as NSString)
      guard tags.artwork != nil || tags.artist != nil else { return }
      DispatchQueue.main.async { completion(tags) }
    }
  }

  private final class Box: NSObject {
    let tags: Tags
    init(tags: Tags) { self.tags = tags }
  }
}

let chatRecoveredAudioTags = ChatRecoveredAudioTags()

/// Resolves a music album cover (mem → disk → network), populating both caches, and
/// calls `completion` on the main thread with the decoded image. Returns the network
/// task, if one was started, so the caller can cancel it on cell reuse.
private let chatMusicCoverInFlightLock = NSLock()
private var chatMusicCoverInFlight: [String: [(UIImage) -> Void]] = [:]

@discardableResult
func chatLoadMusicCover(urlString: String?, completion: @escaping (UIImage) -> Void)
  -> URLSessionDataTask?
{
  guard var trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
    !trimmed.isEmpty
  else { return nil }
  // Protocol-relative og:image values show up from SoundCloud/YouTube scrapes.
  if trimmed.hasPrefix("//") { trimmed = "https:" + trimmed }
  let key = chatMusicCoverCacheKey(trimmed)
  if let cached = chatMediaImageCache.object(forKey: key as NSString) {
    DispatchQueue.main.async { completion(cached) }
    return nil
  }

  chatMusicCoverInFlightLock.lock()
  if chatMusicCoverInFlight[key] != nil {
    chatMusicCoverInFlight[key]?.append(completion)
    chatMusicCoverInFlightLock.unlock()
    return nil
  }
  chatMusicCoverInFlight[key] = [completion]
  chatMusicCoverInFlightLock.unlock()

  let finish: (UIImage?) -> Void = { image in
    chatMusicCoverInFlightLock.lock()
    let callbacks = chatMusicCoverInFlight.removeValue(forKey: key) ?? []
    chatMusicCoverInFlightLock.unlock()
    guard let image else { return }
    DispatchQueue.main.async {
      callbacks.forEach { $0(image) }
    }
  }

  guard let url = URL(string: trimmed) else {
    finish(nil)
    return nil
  }
  let task = VibeHTTP.shared.dataTask(with: url) { data, _, _ in
    guard let data, !data.isEmpty else {
      finish(nil)
      return
    }
    chatMediaDiskCacheQueue.async {
      guard let image = chatMediaDecodedImage(from: data, shouldAnimate: false) else {
        finish(nil)
        return
      }
      chatMediaImageCacheStore(image, forKey: key)
      chatMediaDiskCacheSave(data, forKey: key)
      finish(image)
    }
  }
  // Check disk off-main first; only hit the network on a miss.
  chatMediaDiskCacheQueue.async {
    if let diskData = chatMediaDiskCacheLoad(key),
      let image = chatMediaDecodedImage(from: diskData, shouldAnimate: false)
    {
      chatMediaImageCacheStore(image, forKey: key)
      finish(image)
    } else {
      task.resume()
    }
  }
  return nil
}

/// Pre-fetches a media URL into the in-memory + disk cache so the cell can
/// display it instantly when the optimistic row appears.
func chatMediaPrefetch(urlString: String, animated: Bool) {
  // Must be the SAME key the cell computes, or the prefetch warms a slot nothing reads.
  let cacheKey = chatMediaCacheKey(urlString, mediaKey: nil)
  let rawURLKey = chatMediaLegacyCacheKey(urlString, mediaKey: nil)
  guard !urlString.isEmpty,
    chatMediaImageCache.object(forKey: cacheKey as NSString) == nil,
    !chatMediaFailedURLs.contains(rawURLKey),
    let url = URL(string: urlString)
  else { return }
  let maxPixelSize = chatMediaBubbleDecodeMaxPixelSize()
  // Disk first, off main; only hit the network on a miss.
  chatMediaDiskCacheQueue.async {
    if let diskData = chatMediaDiskCacheLoad(cacheKey, legacyRawKey: rawURLKey),
      let diskImage = chatMediaDecodedImage(
        from: diskData, shouldAnimate: animated, maxPixelSize: maxPixelSize)
    {
      chatMediaImageCacheStore(diskImage, forKey: cacheKey)
      return
    }
    VibeHTTP.shared.dataTask(with: url) { data, _, error in
      guard error == nil, let data, !data.isEmpty else { return }
      chatMediaDiskCacheQueue.async {
        guard
          let image = chatMediaDecodedImage(
            from: data, shouldAnimate: animated, maxPixelSize: maxPixelSize)
        else { return }
        chatMediaImageCacheStore(image, forKey: cacheKey)
        chatMediaDiskCacheSave(data, forKey: cacheKey)
      }
    }.resume()
  }
}

final class ChatCollectionFlowLayout: UICollectionViewFlowLayout {
  // Telegram approach: cells are ALWAYS fully opaque. No fade-in,
  // no fade-out, no transform. ALL visibility is position-based only.

  override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath)
    -> UICollectionViewLayoutAttributes?
  {
    let attrs =
      super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)?.copy()
      as? UICollectionViewLayoutAttributes
    attrs?.alpha = 1.0
    attrs?.transform = .identity
    return attrs
  }

  override func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath)
    -> UICollectionViewLayoutAttributes?
  {
    let attrs =
      super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath)?.copy()
      as? UICollectionViewLayoutAttributes
    attrs?.alpha = 1.0
    attrs?.transform = .identity
    return attrs
  }

  override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]?
  {
    guard let attributes = super.layoutAttributesForElements(in: rect) else { return nil }
    // During normal scrolling all attributes already have alpha=1.0.
    // Only copy + fix during batch updates when UIKit may animate alpha.
    let needsCorrection = attributes.contains { $0.alpha != 1.0 }
    guard needsCorrection else { return attributes }
    return attributes.map { attr in
      let copy = attr.copy() as! UICollectionViewLayoutAttributes
      copy.alpha = 1.0
      return copy
    }
  }

  override func layoutAttributesForItem(at indexPath: IndexPath)
    -> UICollectionViewLayoutAttributes?
  {
    let attrs = super.layoutAttributesForItem(at: indexPath)
    attrs?.alpha = 1.0
    return attrs
  }
}

final class BubbleBackgroundView: UIView {
  private let agentBorderLayer = CAShapeLayer()
  private let wallpaperLayer = CALayer()
  private let blurView = UIVisualEffectView(
    effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
  private let gradientLayer = CAGradientLayer()
  private let fillLayer = CAShapeLayer()
  private let bubbleMaskLayer = CAShapeLayer()
  private var appearance = ChatListAppearance.current
  internal var wallpaperSnapshot: CGImage?
  internal var wallpaperContainerSize: CGSize = .zero
  internal var wallpaperSampleRect: CGRect = .zero
  private var shape = BubbleShape(
    isMe: false, showTail: false, borderTopLeftRadius: 18, borderTopRightRadius: 18,
    borderBottomLeftRadius: 18, borderBottomRightRadius: 18)
  /// Last chrome signature we logged — only emit when fill/grad/wallpaper path flips
  /// (group list flicker investigation).
  private var lastChromeFlickerSignature: String = ""
  /// Optional identity stamped by ChatListCell so logs can name the row.
  var debugRowId: String = ""

  override init(frame: CGRect) {
    super.init(frame: frame)
    wallpaperLayer.contentsGravity = .resize
    wallpaperLayer.contentsScale = UIScreen.main.scale
    layer.addSublayer(wallpaperLayer)
    addSubview(blurView)
    layer.addSublayer(gradientLayer)
    layer.addSublayer(fillLayer)
    gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
    gradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
    layer.mask = bubbleMaskLayer

    let screenScale = UIScreen.main.scale
    agentBorderLayer.contentsScale = screenScale
    gradientLayer.contentsScale = screenScale
    fillLayer.contentsScale = screenScale
    bubbleMaskLayer.contentsScale = screenScale
    layer.allowsEdgeAntialiasing = true
    fillLayer.allowsEdgeAntialiasing = true
    bubbleMaskLayer.allowsEdgeAntialiasing = true
    agentBorderLayer.allowsEdgeAntialiasing = true
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func duplicate() -> BubbleBackgroundView {
    let replica = BubbleBackgroundView(frame: frame)
    replica.configure(isMe: shape.isMe, shape: shape, hidden: false, appearance: appearance)
    if let snapshot = wallpaperSnapshot {
      replica.applyWallpaperBackdrop(
        snapshot: snapshot,
        containerSize: wallpaperContainerSize,
        sampleRect: wallpaperSampleRect
      )
    }
    return replica
  }

  func renderToImage() -> UIImage? {
    // Screen-matched color space (P3) — this raster crossfades against live
    // bubble rendering in the send morph; sRGB baking shifts the gradient tint.
    let format = UIGraphicsImageRendererFormat.preferred()
    format.opaque = false
    format.scale = UIScreen.main.scale
    let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
    return renderer.image { ctx in
      layer.render(in: ctx.cgContext)
    }
  }

  func configure(isMe: Bool, shape: BubbleShape, hidden: Bool, appearance: ChatListAppearance) {
    let previousShape = self.shape
    self.appearance = appearance
    self.shape = shape

    // Check if only the corner radii changed (sequence boundary update). Tail presence must
    // match too: the integrated tail changes the path's segment structure, and CAShapeLayer
    // path animations between structurally different paths glitch.
    let shapeOnlyChange =
      bounds.width > 0 && bounds.height > 0
      && previousShape.isMe == shape.isMe
      && previousShape.showTail == shape.showTail
      && !hidden
      && (abs(previousShape.borderTopLeftRadius - shape.borderTopLeftRadius) > 0.5
        || abs(previousShape.borderTopRightRadius - shape.borderTopRightRadius) > 0.5
        || abs(previousShape.borderBottomLeftRadius - shape.borderBottomLeftRadius) > 0.5
        || abs(previousShape.borderBottomRightRadius - shape.borderBottomRightRadius) > 0.5)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    applyBubbleChrome(isMe: isMe, hidden: hidden, reason: "configure")
    CATransaction.commit()

    if shapeOnlyChange {
      // Animate the shape path transition smoothly (matching Telegram's feel).
      logBubbleFlicker(
        event: "shapeAnimate",
        detail:
          "isMe=\(isMe ? "Y" : "N") tail=\(shape.showTail ? "Y" : "N") hidden=\(hidden ? "Y" : "N")"
      )
      CATransaction.begin()
      CATransaction.setAnimationDuration(0.25)
      CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
      applyShapePath()
      CATransaction.commit()
    } else if bounds.width > 0 && bounds.height > 0 {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      applyShapePath()
      CATransaction.commit()
    }
    setNeedsLayout()
  }

  func applyAgentStyle(appearance: ChatListAppearance, isMe: Bool, accent accentOverride: UIColor? = nil) {
    // Agent chrome = accent BORDER only. Fill/blur come from applyBubbleChrome so a
    // configure → wallpaperOn → agentStyle sequence does not thrash three plate colors
    // (#252936 solid → #181C26 wallpaper → #191E27 agent wash). Logs proved that cascade
    // was the group-list flicker.
    let agentColor =
      accentOverride
      ?? appearance.bubbleMeGradient.first ?? UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0)
    let prevFill =
      chatCellBubbleFlickerDebugLogs ? Self.debugColorHex(fillLayer.fillColor) : nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    if isMe {
      // Agent mention on me side: shared me gradient must stay visible (clear fill).
      fillLayer.fillColor = UIColor.clear.cgColor
      applySharedMeGradient(opacity: 1.0)
      blurView.alpha = 0.0
    }
    // them-side agent: leave fill/gradient/blur alone (stable them plate from chrome).

    if agentBorderLayer.superlayer == nil {
      layer.addSublayer(agentBorderLayer)
    }
    agentBorderLayer.fillColor = UIColor.clear.cgColor
    agentBorderLayer.strokeColor = agentColor.withAlphaComponent(isMe ? 0.46 : 0.24).cgColor
    agentBorderLayer.lineWidth = 1.5
    applyAgentBorderPath()
    CATransaction.commit()
    if let prevFill {
      let nextFill = Self.debugColorHex(fillLayer.fillColor)
      guard prevFill != nextFill else { return }
      logBubbleFlicker(
        event: "agentStyle",
        detail:
          "path=borderOnly isMe=\(isMe ? "Y" : "N") fill \(prevFill)->\(nextFill) "
          + "accent=\(Self.debugColorHex(agentColor.cgColor)) override=\(accentOverride != nil ? "Y" : "N")"
      )
    }
  }

  func clearAgentStyle() {
    let hadBorder =
      chatCellBubbleFlickerDebugLogs
      && (agentBorderLayer.path != nil
        || (agentBorderLayer.strokeColor != nil
          && agentBorderLayer.strokeColor != UIColor.clear.cgColor))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    agentBorderLayer.path = nil
    agentBorderLayer.strokeColor = UIColor.clear.cgColor
    CATransaction.commit()
    if hadBorder {
      logBubbleFlicker(event: "clearAgentStyle", detail: "borderCleared")
    }
  }

  func applyWallpaperBackdrop(
    snapshot: CGImage?,
    containerSize: CGSize,
    sampleRect: CGRect
  ) {
    let prevHas =
      wallpaperSnapshot != nil
      && wallpaperContainerSize.width > 1.0
      && wallpaperContainerSize.height > 1.0
    let nextHas =
      snapshot != nil
      && containerSize.width > 1.0
      && containerSize.height > 1.0
    // Presence unchanged → only sample geometry moved (scroll). Re-running chrome/agent
    // plate math every frame was rewriting fill and looking like a color transition.
    let sampleOnly = prevHas == nextHas
    wallpaperSnapshot = snapshot
    wallpaperContainerSize = containerSize
    wallpaperSampleRect = sampleRect
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if sampleOnly {
      // Me gradient endpoints track list-space sample rect; them plate hue is fixed.
      if shape.isMe, !gradientLayer.isHidden {
        applySharedMeGradient(opacity: gradientLayer.opacity)
      }
      applyWallpaperBackdropLayer()
    } else {
      applyBubbleChrome(
        isMe: shape.isMe,
        hidden: isHidden,
        reason: nextHas ? "wallpaperOn" : "wallpaperOff"
      )
      applyWallpaperBackdropLayer()
    }
    CATransaction.commit()
    if !sampleOnly {
      setNeedsLayout()
    }
  }

  private static func debugColorHex(_ cgColor: CGColor?) -> String {
    guard let cgColor, let color = UIColor(cgColor: cgColor).cgColor.components else {
      return "nil"
    }
    let r: CGFloat
    let g: CGFloat
    let b: CGFloat
    let a: CGFloat
    if color.count >= 4 {
      r = color[0]
      g = color[1]
      b = color[2]
      a = color[3]
    } else if color.count >= 2 {
      r = color[0]
      g = color[0]
      b = color[0]
      a = color[1]
    } else {
      return "unk"
    }
    return String(
      format: "#%02X%02X%02X@%.2f",
      Int((r * 255.0).rounded()),
      Int((g * 255.0).rounded()),
      Int((b * 255.0).rounded()),
      a
    )
  }

  private func logBubbleFlicker(event: String, detail: String) {
    guard chatCellBubbleFlickerDebugLogs else { return }
    let id = debugRowId.isEmpty ? "—" : debugRowId
    NSLog("[BubbleFlicker] %@ id=%@ %@", event, id, detail)
  }

  /// nil = no integrated tail; otherwise the side flag passed to `bubblePath`.
  private var integratedTailSide: Bool? {
    (shape.showTail && integratedTailEnabled) ? shape.isMe : nil
  }

  /// Cell-level suppression (ghost rows, typing, stickers, full-bleed media, centered agent
  /// "thinking" bubble) on top of `shape.showTail` — the shape says a tail belongs to this
  /// row, the cell says whether this particular presentation may draw it.
  private var integratedTailEnabled = true

  func setIntegratedTailEnabled(_ enabled: Bool) {
    guard integratedTailEnabled != enabled else { return }
    integratedTailEnabled = enabled
    guard bounds.width > 0, bounds.height > 0 else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    applyShapePath()
    applyAgentBorderPath()
    CATransaction.commit()
  }

  private func applyAgentBorderPath() {
    guard bounds.width > 0, bounds.height > 0 else { return }
    let path = bubblePath(
      rect: bounds,
      topLeft: shape.borderTopLeftRadius,
      topRight: shape.borderTopRightRadius,
      bottomRight: shape.borderBottomRightRadius,
      bottomLeft: shape.borderBottomLeftRadius,
      tailOnRight: integratedTailSide
    )
    agentBorderLayer.frame = bounds
    agentBorderLayer.path = path.cgPath
  }

  private func applyShapePath() {
    let path = bubblePath(
      rect: bounds,
      topLeft: shape.borderTopLeftRadius,
      topRight: shape.borderTopRightRadius,
      bottomRight: shape.borderBottomRightRadius,
      bottomLeft: shape.borderBottomLeftRadius,
      tailOnRight: integratedTailSide
    )
    // The tail path extends past the trailing (+ slightly below) bounds, so
    // bounded-content layers (gradient, wallpaper sample, blur) must paint larger
    // than the view; the view-level bubbleMaskLayer clips back to the silhouette.
    // CAShapeLayers (mask + fill) render their full path regardless of bounds.
    let hPad = bubbleTailOverhang + 2.0
    let paintRect = CGRect(
      x: bounds.minX - hPad,
      y: bounds.minY,
      width: bounds.width + 2.0 * hPad,
      height: bounds.height + bubbleTailBottomOverhang + 1.0
    )
    wallpaperLayer.frame = paintRect
    blurView.frame = paintRect
    bubbleMaskLayer.frame = bounds
    bubbleMaskLayer.path = path.cgPath
    gradientLayer.frame = paintRect
    // No per-layer gradient mask: the view-level mask already clips the gradient to the
    // bubble+tail path (a bounds-anchored sub-mask would mis-register against paintRect).
    gradientLayer.mask = nil
    fillLayer.frame = bounds
    fillLayer.path = path.cgPath
    // Endpoints depend on gradient layer bounds — refresh shared me mapping after frame set.
    if !gradientLayer.isHidden, shape.isMe {
      applySharedMeGradient(opacity: gradientLayer.opacity)
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    applyShapePath()
    applyWallpaperBackdropLayer()
    applyAgentBorderPath()
    CATransaction.commit()
  }

  private func applyWallpaperBackdropLayer() {
    let hasBackdrop =
      wallpaperSnapshot != nil
      && wallpaperContainerSize.width > 1.0
      && wallpaperContainerSize.height > 1.0
      && appearance.backgroundMode != "transparent"

    wallpaperLayer.isHidden = !hasBackdrop
    guard hasBackdrop, let wallpaperSnapshot else {
      wallpaperLayer.contents = nil
      return
    }

    wallpaperLayer.contents = wallpaperSnapshot
    // wallpaperLayer paints wider than bounds (tail overhang — see applyShapePath), so the
    // sample rect must widen by the same amount to stay registered with the backdrop.
    let hPad = bubbleTailOverhang + 2.0
    let sampleRect = CGRect(
      x: wallpaperSampleRect.minX - hPad,
      y: wallpaperSampleRect.minY,
      width: wallpaperSampleRect.width + 2.0 * hPad,
      height: wallpaperSampleRect.height + bubbleTailBottomOverhang + 1.0
    )
    wallpaperLayer.contentsRect = normalizedWallpaperSampleRect(
      sampleRect,
      containerSize: wallpaperContainerSize
    )
  }

  private func applyBubbleChrome(isMe: Bool, hidden: Bool, reason: String = "chrome") {
    let hasWallpaperBackdrop =
      wallpaperSnapshot != nil
      && wallpaperContainerSize.width > 1.0
      && wallpaperContainerSize.height > 1.0
      && appearance.backgroundMode != "transparent"

    let previousChrome: (
      fill: String, gradientHidden: Bool, gradientOpacity: Float, blurAlpha: CGFloat
    )? =
      chatCellBubbleFlickerDebugLogs
      ? (
        Self.debugColorHex(fillLayer.fillColor), gradientLayer.isHidden,
        gradientLayer.opacity, blurView.alpha
      )
      : nil

    isHidden = hidden
    wallpaperLayer.isHidden = hidden || !hasWallpaperBackdrop
    wallpaperLayer.opacity = Float(
      hasWallpaperBackdrop
        ? (isMe ? appearance.outgoingWallpaperSampleOpacity : appearance.incomingWallpaperSampleOpacity)
        : 1.0
    )
    blurView.isHidden = hidden
    // Material style follows chat theme dark/light (not always-dark).
    let material: UIBlurEffect.Style =
      appearance.isDark
      ? (isMe ? .systemThinMaterialDark : .systemMaterialDark)
      : (isMe ? .systemThinMaterialLight : .systemMaterialLight)
    blurView.effect = UIBlurEffect(style: material)
    // Them plate is near-opaque and theme-stable — same fill with or without wallpaper
    // snapshot so configure→bindWallpaper never flashes #252936 → #181C26.
    // Me still uses a light material wash only when there is no wallpaper sample.
    let materialAlpha: CGFloat
    if hasWallpaperBackdrop {
      materialAlpha = 0.0
    } else if isMe {
      materialAlpha = 0.34
    } else {
      materialAlpha = 0.0
    }
    blurView.alpha = materialAlpha
    let platePath: String
    // Them: one fixed plate color always (wallpaperPlateColor ignores sample hue).
    // Me: clear fill under shared list-space theme gradient.
    if isMe {
      fillLayer.fillColor = UIColor.clear.cgColor
      applySharedMeGradient(opacity: 1.0)
      platePath = hasWallpaperBackdrop ? "wallpaper+meGradient" : "noWall+meGradient"
    } else {
      let plateSample =
        wallpaperSampleRect.width > 1 && wallpaperSampleRect.height > 1
        ? wallpaperSampleRect
        : CGRect(x: 0, y: 0, width: 1, height: 1)
      let plateContainer =
        wallpaperContainerSize.width > 1 && wallpaperContainerSize.height > 1
        ? wallpaperContainerSize
        : CGSize(width: 1, height: 1)
      let plateColor = appearance.wallpaperPlateColor(
        isMe: false,
        sampleRect: plateSample,
        containerSize: plateContainer
      )
      fillLayer.fillColor = plateColor.withAlphaComponent(appearance.incomingPlateFillOpacity)
        .cgColor
      gradientLayer.isHidden = true
      gradientLayer.opacity = 0.0
      gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
      gradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
      platePath = hasWallpaperBackdrop ? "wallpaper+themPlate" : "noWall+themPlate"
    }

    guard let previousChrome else { return }
    let nextFill = Self.debugColorHex(fillLayer.fillColor)
    // Signature ignores sample rect so scroll-driven rebinds only log real chrome flips.
    let signature =
      "\(platePath)|me=\(isMe ? "Y" : "N")|hid=\(hidden ? "Y" : "N")|"
      + "wall=\(hasWallpaperBackdrop ? "Y" : "N")|fill=\(nextFill)|"
      + "gradH=\(gradientLayer.isHidden ? "Y" : "N")@\(String(format: "%.2f", gradientLayer.opacity))|"
      + "blur=\(String(format: "%.2f", blurView.alpha))|"
      + "dark=\(appearance.isDark ? "Y" : "N")|mode=\(appearance.backgroundMode)"
    let colorChanged =
      previousChrome.fill != nextFill
      || previousChrome.gradientHidden != gradientLayer.isHidden
      || abs(previousChrome.gradientOpacity - gradientLayer.opacity) > 0.01
      || abs(previousChrome.blurAlpha - blurView.alpha) > 0.01
    if signature != lastChromeFlickerSignature || colorChanged {
      lastChromeFlickerSignature = signature
      logBubbleFlicker(
        event: "chrome",
        detail:
          "reason=\(reason) \(signature) prevFill=\(previousChrome.fill) sample=(\(Int(wallpaperSampleRect.minX)),\(Int(wallpaperSampleRect.minY)),\(Int(wallpaperSampleRect.width))x\(Int(wallpaperSampleRect.height)))"
      )
    }
  }

  /// Positions `gradientLayer` as a slice of one chat-list-wide me gradient.
  /// When sample/container geometry is missing, falls back to a soft local diagonal
  /// (still one theme palette — not wallpaper-sampled per cell).
  private func applySharedMeGradient(opacity: Float) {
    let colors = appearance.bubbleMeGradient.map(\.cgColor)
    guard !colors.isEmpty else {
      gradientLayer.isHidden = true
      gradientLayer.opacity = 0.0
      return
    }
    gradientLayer.isHidden = false
    gradientLayer.colors = colors
    gradientLayer.locations = nil
    gradientLayer.opacity = opacity
    let layerBounds =
      gradientLayer.bounds.width > 1 && gradientLayer.bounds.height > 1
      ? gradientLayer.bounds
      : (bounds.width > 1 ? bounds : CGRect(x: 0, y: 0, width: 1, height: 1))
    if let points = appearance.sharedBubbleGradientUnitPoints(
      sampleRectInContainer: wallpaperSampleRect,
      containerSize: wallpaperContainerSize,
      layerBounds: layerBounds
    ) {
      gradientLayer.startPoint = points.start
      gradientLayer.endPoint = points.end
    } else {
      // Local fallback: diagonal but slightly compressed so tall cells don't
      // dump the entire palette top→bottom as harshly as 0,0→1,1 full stretch.
      gradientLayer.startPoint = CGPoint(x: 0.05, y: 0.0)
      gradientLayer.endPoint = CGPoint(x: 0.95, y: 1.15)
    }
  }

  /// Bubble outline, optionally with the Telegram-style tail hook drawn INTO the path.
  /// `tailOnRight`: nil = no tail; true = tail at bottom-right (me); false = bottom-left
  /// (them). The tail replaces that side's bottom corner contour and extends up to
  /// ~`bubbleTailOverhang`pt beyond `rect` horizontally — callers' paint layers must cover
  /// that overhang (see `applyShapePath`). Drawing the tail as part of the ONE body path is
  /// what guarantees tail and body share the exact same fill/gradient/blur/wallpaper plate:
  /// no color seam, no sliver poking outside the corner curve, no separate-view resolution
  /// issues (all previous failure modes of the rotated `BubbleTailView` approach).
  private func bubblePath(
    rect: CGRect, topLeft: CGFloat, topRight: CGFloat, bottomRight: CGFloat, bottomLeft: CGFloat,
    tailOnRight: Bool? = nil
  ) -> UIBezierPath {
    let width = max(1.0, rect.width)
    let height = max(1.0, rect.height)
    let tl = min(max(0.0, topLeft), min(width, height) * 0.5)
    let tr = min(max(0.0, topRight), min(width, height) * 0.5)
    let br = min(max(0.0, bottomRight), min(width, height) * 0.5)
    let bl = min(max(0.0, bottomLeft), min(width, height) * 0.5)
    // Tail proportions follow the cell's primary corner, not the intentionally tight
    // grouped corner on the tail side (e.g. the appearance preview's 0.35× corner).
    let tailRadius = max(tl, tr, br, bl)

    let path = UIBezierPath()
    path.move(to: CGPoint(x: tl, y: 0.0))
    path.addLine(to: CGPoint(x: width - tr, y: 0.0))
    path.addArc(
      withCenter: CGPoint(x: width - tr, y: tr), radius: tr, startAngle: 3 * .pi / 2, endAngle: 0.0,
      clockwise: true)
    if tailOnRight == true {
      addTelegramReferenceTail(
        onRight: true, to: path, width: width, height: height, radius: tailRadius,
        curvature: appearance.messageTailCurvature)
    } else {
      path.addLine(to: CGPoint(x: width, y: height - br))
      path.addArc(
        withCenter: CGPoint(x: width - br, y: height - br), radius: br, startAngle: 0.0,
        endAngle: .pi / 2, clockwise: true)
    }
    if tailOnRight == false {
      addTelegramReferenceTail(
        onRight: false, to: path, width: width, height: height, radius: tailRadius,
        curvature: appearance.messageTailCurvature)
    } else {
      path.addLine(to: CGPoint(x: bl, y: height))
      path.addArc(
        withCenter: CGPoint(x: bl, y: height - bl), radius: bl, startAngle: .pi / 2, endAngle: .pi,
        clockwise: true)
      path.addLine(to: CGPoint(x: 0.0, y: tl))
    }
    path.addArc(
      withCenter: CGPoint(x: tl, y: tl), radius: tl, startAngle: .pi, endAngle: 3 * .pi / 2,
      clockwise: true)
    path.close()
    return path
  }

  /// One normalized source for the outgoing/incoming tail. At curvature 1 the three
  /// cubics are the screenshot's right-edge→tip→notch→bottom contour, normalized to an
  /// 18pt primary corner. Lower values interpolate toward a compact straight-segment
  /// tail without ever creating a separate layer or a zero-area path.
  private struct TelegramReferenceTailGeometry {
    let outerStart: CGPoint
    let outerControl1: CGPoint
    let outerControl2: CGPoint
    let tip: CGPoint
    let innerControl1: CGPoint
    let innerControl2: CGPoint
    let notch: CGPoint
    let cornerControl1: CGPoint
    let cornerControl2: CGPoint
    let bottomJoin: CGPoint

    static func resolved(
      width: CGFloat, height: CGFloat, radius: CGFloat, curvature: CGFloat, onRight: Bool
    ) -> TelegramReferenceTailGeometry {
      let scale = max(0.0, radius / 18.0)
      let originX = onRight ? width : 0.0
      let t = max(0.0, min(1.0, curvature))

      // Body-aligned fit against Telegram's outgoing tail. In particular, the inner
      // control stays above the baseline (no downward hook), the tip overhang is shorter,
      // and the bottom join begins farther inward so the tail grows from the body.
      let referenceOuterStart = CGPoint(x: 0.0000, y: -7.7280)
      let referenceOuterControl1 = CGPoint(x: 0.4310, y: -5.4310)
      let referenceOuterControl2 = CGPoint(x: 1.9830, y: -2.2870)
      let referenceTip = CGPoint(x: 4.6380, y: 0.0000)
      let referenceInnerControl1 = CGPoint(x: 0.9830, y: -0.4090)
      let referenceInnerControl2 = CGPoint(x: -4.4190, y: -0.6970)
      let referenceNotch = CGPoint(x: -7.7280, y: -3.4780)
      let referenceCornerControl1 = CGPoint(x: -10.5260, y: -1.6100)
      let referenceCornerControl2 = CGPoint(x: -13.7070, y: -0.6630)
      let referenceBottomJoin = CGPoint(x: -17.0020, y: 0.0000)

      // The straight endpoint stays intentionally non-degenerate. It is 58% of the
      // reference footprint, with cubic controls on each chord, so the slider reduces
      // both the hook's bend and its visual thickness while preserving a crisp tail.
      let compactScale: CGFloat = 0.58
      func compact(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * compactScale, y: point.y * compactScale)
      }
      let straightOuterStart = compact(referenceOuterStart)
      let straightTip = compact(referenceTip)
      let straightNotch = compact(referenceNotch)
      let straightBottomJoin = compact(referenceBottomJoin)
      func chordPoint(_ start: CGPoint, _ end: CGPoint, _ fraction: CGFloat) -> CGPoint {
        CGPoint(
          x: start.x + (end.x - start.x) * fraction,
          y: start.y + (end.y - start.y) * fraction
        )
      }
      func adjustable(_ straight: CGPoint, _ reference: CGPoint) -> CGPoint {
        // Preserve the validated reference coordinates byte-for-byte at the default.
        guard t < 0.999_999 else { return reference }
        return CGPoint(
          x: straight.x + (reference.x - straight.x) * t,
          y: straight.y + (reference.y - straight.y) * t
        )
      }
      func transformed(_ point: CGPoint) -> CGPoint {
        CGPoint(
          x: originX + (onRight ? point.x : -point.x) * scale,
          y: height + point.y * scale
        )
      }
      return TelegramReferenceTailGeometry(
        outerStart: transformed(adjustable(straightOuterStart, referenceOuterStart)),
        outerControl1: transformed(
          adjustable(chordPoint(straightOuterStart, straightTip, 1.0 / 3.0), referenceOuterControl1)
        ),
        outerControl2: transformed(
          adjustable(chordPoint(straightOuterStart, straightTip, 2.0 / 3.0), referenceOuterControl2)
        ),
        tip: transformed(adjustable(straightTip, referenceTip)),
        innerControl1: transformed(
          adjustable(chordPoint(straightTip, straightNotch, 1.0 / 3.0), referenceInnerControl1)
        ),
        innerControl2: transformed(
          adjustable(chordPoint(straightTip, straightNotch, 2.0 / 3.0), referenceInnerControl2)
        ),
        notch: transformed(adjustable(straightNotch, referenceNotch)),
        cornerControl1: transformed(
          adjustable(
            chordPoint(straightNotch, straightBottomJoin, 1.0 / 3.0),
            referenceCornerControl1)
        ),
        cornerControl2: transformed(
          adjustable(
            chordPoint(straightNotch, straightBottomJoin, 2.0 / 3.0),
            referenceCornerControl2)
        ),
        bottomJoin: transformed(adjustable(straightBottomJoin, referenceBottomJoin))
      )
    }
  }

  private func appendTelegramReferenceTailCurves(
    onRight: Bool,
    geometry: TelegramReferenceTailGeometry,
    to path: UIBezierPath
  ) {
    if onRight {
      path.addCurve(
        to: geometry.tip,
        controlPoint1: geometry.outerControl1,
        controlPoint2: geometry.outerControl2
      )
      path.addCurve(
        to: geometry.notch,
        controlPoint1: geometry.innerControl1,
        controlPoint2: geometry.innerControl2
      )
      path.addCurve(
        to: geometry.bottomJoin,
        controlPoint1: geometry.cornerControl1,
        controlPoint2: geometry.cornerControl2
      )
    } else {
      path.addCurve(
        to: geometry.notch,
        controlPoint1: geometry.cornerControl2,
        controlPoint2: geometry.cornerControl1
      )
      path.addCurve(
        to: geometry.tip,
        controlPoint1: geometry.innerControl2,
        controlPoint2: geometry.innerControl1
      )
      path.addCurve(
        to: geometry.outerStart,
        controlPoint1: geometry.outerControl2,
        controlPoint2: geometry.outerControl1
      )
    }
  }

  private func addTelegramReferenceTail(
    onRight: Bool,
    to path: UIBezierPath,
    width: CGFloat,
    height: CGFloat,
    radius: CGFloat,
    curvature: CGFloat
  ) {
    guard radius > 0.5 else {
      if onRight {
        path.addLine(to: CGPoint(x: width, y: height))
      } else {
        path.addLine(to: CGPoint(x: 0.0, y: height))
      }
      return
    }

    let geometry = TelegramReferenceTailGeometry.resolved(
      width: width, height: height, radius: radius, curvature: curvature, onRight: onRight)

    if onRight {
      path.addLine(to: geometry.outerStart)
      appendTelegramReferenceTailCurves(onRight: true, geometry: geometry, to: path)
    } else {
      path.addLine(to: geometry.bottomJoin)
      appendTelegramReferenceTailCurves(onRight: false, geometry: geometry, to: path)
      path.addLine(to: CGPoint(x: 0.0, y: tlSafeTop(radius: radius, height: height)))
    }
  }

  private func tlSafeTop(radius: CGFloat, height: CGFloat) -> CGFloat {
    min(radius, height)
  }

  /// Clamped per-corner radii of the current shape at the current bounds. The
  /// send morph builds the plate raster's stretch-safe cap insets and the clip
  /// envelope's settled rounding from these (a grouped consecutive send has a
  /// reduced top-trailing radius that must be honored during the flight, not
  /// snapped in at reveal).
  func transitionCornerRadii() -> (
    topLeft: CGFloat, topRight: CGFloat, bottomLeft: CGFloat, bottomRight: CGFloat
  ) {
    let width = max(1.0, bounds.width)
    let height = max(1.0, bounds.height)
    let limit = min(width, height) * 0.5
    func clamp(_ value: CGFloat) -> CGFloat { min(max(0.0, value), limit) }
    return (
      clamp(shape.borderTopLeftRadius), clamp(shape.borderTopRightRadius),
      clamp(shape.borderBottomLeftRadius), clamp(shape.borderBottomRightRadius)
    )
  }

  /// Snapshot mask around the three-cubic tail contour. The send morph captures this
  /// small lobe separately from the rounded plate so width/height interpolation can
  /// never stretch the tail. nil when this bubble draws no integrated tail.
  func integratedTailLobePath() -> UIBezierPath? {
    guard let onRight = integratedTailSide, bounds.width > 1.0, bounds.height > 1.0 else {
      return nil
    }
    let width = max(1.0, bounds.width)
    let height = max(1.0, bounds.height)
    let radiusLimit = min(width, height) * 0.5
    let radius = [
      shape.borderTopLeftRadius, shape.borderTopRightRadius,
      shape.borderBottomLeftRadius, shape.borderBottomRightRadius,
    ].map { min(max(0.0, $0), radiusLimit) }.max() ?? 0.0
    guard radius > 0.5 else { return nil }

    let geometry = TelegramReferenceTailGeometry.resolved(
      width: width, height: height, radius: radius,
      curvature: appearance.messageTailCurvature, onRight: onRight)

    // The morph plate is captured with the tail SUPPRESSED, which bakes the
    // bottom-trailing corner as a rounded arc at THIS radius (br / bl). The tail
    // cubics, however, are scaled by `radius` = the bubble's MAX corner — so a
    // straight chord back from bottomJoin runs INSIDE the plate's arc and the
    // arc's bulge is covered by neither piece: the ~sub-pixel crescent the user
    // sees as a "tiny gap where the tail meets the body" (the radius mismatch).
    // Closing the lobe along the SAME arc the plate baked makes lobe.innerEdge ≡
    // plate.outerEdge, so plate ∪ lobe reconstructs the real bubble with no gap
    // and without overfilling the concave notch (which sits just outside the arc).
    let plateCornerRadius = min(
      max(0.0, onRight ? shape.borderBottomRightRadius : shape.borderBottomLeftRadius),
      radiusLimit)
    let path = UIBezierPath()
    if onRight {
      path.move(to: geometry.outerStart)
      appendTelegramReferenceTailCurves(onRight: true, geometry: geometry, to: path)
      path.addLine(to: CGPoint(x: width - plateCornerRadius, y: height))
      path.addArc(
        withCenter: CGPoint(x: width - plateCornerRadius, y: height - plateCornerRadius),
        radius: plateCornerRadius, startAngle: .pi / 2, endAngle: 0.0, clockwise: false)
      // close() runs the right edge from (width, height-plateCornerRadius) up to outerStart
    } else {
      path.move(to: geometry.bottomJoin)
      appendTelegramReferenceTailCurves(onRight: false, geometry: geometry, to: path)
      path.addLine(to: CGPoint(x: plateCornerRadius, y: height))
      path.addArc(
        withCenter: CGPoint(x: plateCornerRadius, y: height - plateCornerRadius),
        radius: plateCornerRadius, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
    }
    path.close()
    return path
  }
}

/// Paint/capture reserve for the integrated tail at the maximum supported 26pt corner.
/// The fitted cubic reaches 4.64pt at radius 18 and 6.70pt at radius 26; retain the
/// existing 7.8pt reserve so send-morph snapshots keep generous antialias coverage.
let bubbleTailOverhang: CGFloat = 7.8
/// The fitted curve stays on/above the plate bottom; this is antialias coverage only.
let bubbleTailBottomOverhang: CGFloat = 0.5

private let bubbleMessageFont = UIFont.systemFont(ofSize: 16)
/// Monospaced digits, and that is load-bearing rather than typographic taste.
///
/// The timestamp is part of the bubble's minimum width (`measuredTextWidth(row.timestamp,
/// …)`), and in the proportional system font `1` is roughly two points narrower than the
/// other digits. So "18:11" measures narrower than "17:04", and a column of identical
/// one-word messages came out at visibly different widths — a ragged left edge down the
/// whole transcript that no amount of layout work could explain, because the layout was
/// faithfully rendering two different widths. Fixed digit advance makes every timestamp
/// of the same length the same width, which makes the bubble width a function of the
/// message instead of the minute it was sent.
private let bubbleMetaFont = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
private let bubbleMetaStatusFont = UIFont.systemFont(ofSize: 11, weight: .semibold)
private let bubbleMetaInlineSpacing: CGFloat = 4.0
private let bubbleMetaItemGap: CGFloat = 2.0
private let bubbleRTLTailSideReserve: CGFloat = 0.0
private let bubbleStatusSlotWidth: CGFloat = 17.0
private let bubbleStatusSlotHeight: CGFloat = 14.0

private final class ChatPendingStatusView: UIView {
  private let ringLayer = CAShapeLayer()
  private let staticHandLayer = CAShapeLayer()
  private let handLayer = CAShapeLayer()
  private var color = UIColor.white

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    ringLayer.fillColor = UIColor.clear.cgColor
    ringLayer.lineCap = .round
    ringLayer.opacity = 0.58
    staticHandLayer.fillColor = UIColor.clear.cgColor
    staticHandLayer.lineCap = .round
    handLayer.fillColor = UIColor.clear.cgColor
    handLayer.lineCap = .round
    layer.addSublayer(ringLayer)
    layer.addSublayer(staticHandLayer)
    layer.addSublayer(handLayer)
  }

  required init?(coder: NSCoder) {
    nil
  }

  func configure(color: UIColor) {
    self.color = color
    ringLayer.strokeColor = color.cgColor
    staticHandLayer.strokeColor = color.cgColor
    handLayer.strokeColor = color.cgColor
    setNeedsLayout()
    startAnimating()
  }

  func stopAnimating() {
    handLayer.removeAnimation(forKey: "pendingClockRotation")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let side = min(bounds.width, bounds.height) - 4.0
    let rect = CGRect(
      x: floor((bounds.width - side) * 0.5),
      y: floor((bounds.height - side) * 0.5),
      width: side,
      height: side
    )
    let lineWidth = max(1.2, side * 0.13)
    ringLayer.frame = bounds
    ringLayer.lineWidth = lineWidth
    ringLayer.path = UIBezierPath(ovalIn: rect).cgPath

    staticHandLayer.frame = bounds
    staticHandLayer.lineWidth = lineWidth
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let radius = side * 0.30
    let staticPath = UIBezierPath()
    staticPath.move(to: center)
    staticPath.addLine(to: CGPoint(x: center.x + radius * 0.42, y: center.y))
    staticHandLayer.path = staticPath.cgPath

    handLayer.frame = bounds
    handLayer.lineWidth = lineWidth
    let path = UIBezierPath()
    path.move(to: center)
    path.addLine(to: CGPoint(x: center.x, y: center.y - radius * 1.12))
    handLayer.path = path.cgPath
  }

  private func startAnimating() {
    if handLayer.animation(forKey: "pendingClockRotation") != nil { return }
    let animation = CABasicAnimation(keyPath: "transform.rotation.z")
    animation.fromValue = 0.0
    animation.toValue = CGFloat.pi * 2.0
    animation.duration = 1.05
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: .linear)
    animation.isRemovedOnCompletion = false
    handLayer.add(animation, forKey: "pendingClockRotation")
  }
}

private func pixelAlignedRect(_ rect: CGRect) -> CGRect {
  let scale = max(UIScreen.main.scale, 1.0)
  let minX = floor(rect.minX * scale) / scale
  let minY = floor(rect.minY * scale) / scale
  let maxX = ceil(rect.maxX * scale) / scale
  let maxY = ceil(rect.maxY * scale) / scale
  return CGRect(x: minX, y: minY, width: max(0.0, maxX - minX), height: max(0.0, maxY - minY))
}

// MARK: - Outer tall-bubble glass toggle (hosted by ChatListView, not the cell)

/// Real template-vector assets for the tall-bubble glass chip. The asset catalog keeps
/// the SVG path data, while `.alwaysTemplate` lets each bubble side/theme supply tint.
enum ChatTallToggleGlyph {
  /// `collapsed == true` → outward-corner expand glyph.
  /// `collapsed == false` → inward-corner collapse glyph supplied by design.
  static func image(collapsed: Bool) -> UIImage? {
    let assetName = collapsed ? "TallBubbleExpand" : "TallBubbleCollapse"
    if let asset = UIImage(named: assetName) {
      return asset.withRenderingMode(.alwaysTemplate)
    }
    // Defensive fallback for development builds whose asset catalog is stale.
    let symbolName = collapsed ? "chevron.down" : "chevron.up"
    return UIImage(
      systemName: symbolName,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .semibold)
    )?.withRenderingMode(.alwaysTemplate)
  }
}

/// Floating glass expand/collapse control — sits OUTSIDE the list cell, over the
/// wallpaper, so Liquid Glass can sample the chat backdrop cleanly.
final class ChatTallBubbleGlassToggleView: UIView {
  var onTap: (() -> Void)?
  private(set) var messageId: String = ""
  private(set) var isCollapsed: Bool = true

  private let glassView: UIVisualEffectView
  private let iconView = UIImageView()
  private let button = UIButton(type: .custom)

  override init(frame: CGRect) {
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect(style: .regular)
      effect.isInteractive = true
      glassView = UIVisualEffectView(effect: effect)
    } else {
      glassView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    }
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false

    glassView.translatesAutoresizingMaskIntoConstraints = false
    glassView.clipsToBounds = true
    glassView.layer.cornerCurve = .continuous
    if #available(iOS 26.0, *) {
      // UIGlassEffect owns the shape via the button chrome; still clip for fallback.
    }
    addSubview(glassView)

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.contentMode = .scaleAspectFit
    iconView.isUserInteractionEnabled = false
    glassView.contentView.addSubview(iconView)

    button.translatesAutoresizingMaskIntoConstraints = false
    button.backgroundColor = .clear
    button.accessibilityTraits = .button
    button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    addSubview(button)

    let glassSize = tallBubbleGlassToggleSize
    NSLayoutConstraint.activate([
      glassView.centerXAnchor.constraint(equalTo: centerXAnchor),
      glassView.centerYAnchor.constraint(equalTo: centerYAnchor),
      glassView.widthAnchor.constraint(equalToConstant: glassSize),
      glassView.heightAnchor.constraint(equalToConstant: glassSize),
      iconView.centerXAnchor.constraint(equalTo: glassView.contentView.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: glassView.contentView.centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: glassSize * 0.52),
      iconView.heightAnchor.constraint(equalToConstant: glassSize * 0.52),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    glassView.layer.cornerRadius = glassSize * 0.5
    applyIcon(collapsed: true, animated: false)
  }

  required init?(coder: NSCoder) { return nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    glassView.layer.cornerRadius = min(glassView.bounds.width, glassView.bounds.height) * 0.5
  }

  func configure(
    messageId: String,
    collapsed: Bool,
    iconColor: UIColor,
    animated: Bool
  ) {
    self.messageId = messageId
    let stateChanged = self.isCollapsed != collapsed
    self.isCollapsed = collapsed
    iconView.tintColor = iconColor
    button.accessibilityLabel = collapsed ? "Show more" : "Show less"
    applyIcon(collapsed: collapsed, animated: animated && stateChanged)
  }

  private func applyIcon(collapsed: Bool, animated: Bool) {
    let image = ChatTallToggleGlyph.image(collapsed: collapsed)
    if animated {
      // One image view avoids the old parent-alpha bug (the incoming icon was a child of
      // the outgoing icon, so fading the parent hid both). The distinct SVGs dissolve.
      UIView.transition(
        with: iconView,
        duration: 0.20,
        options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState],
        animations: { self.iconView.image = image },
        completion: nil
      )
    } else {
      iconView.layer.removeAllAnimations()
      iconView.image = image
      iconView.alpha = 1.0
      iconView.transform = .identity
    }
  }

  @objc private func handleTap() {
    // Keep feedback INSIDE the glass wrapper: only the vector glyph compresses and
    // rebounds. Scaling the glass plate made the icon appear to animate outside it.
    UIView.animate(
      withDuration: 0.09,
      delay: 0,
      options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseIn],
      animations: { self.iconView.transform = CGAffineTransform(scaleX: 0.76, y: 0.76) },
      completion: { _ in
        UIView.animate(
          withDuration: 0.20,
          delay: 0,
          usingSpringWithDamping: 0.68,
          initialSpringVelocity: 0.55,
          options: [.allowUserInteraction, .beginFromCurrentState],
          animations: { self.iconView.transform = .identity },
          completion: nil)
      })
    onTap?()
  }
}

/// Snapshot a cell exposes so ChatListView can place the outer glass toggle.
struct ChatTallToggleAnchor {
  let messageId: String
  let bubbleFrameInCell: CGRect
  let collapsed: Bool
  let isMe: Bool
}

/// Rendered ticks, keyed by shape + resolved colour. Two shapes and a handful of ink
/// colours, so this stays tiny; without it every cell configure ran a full raster pass.
private let bubbleStatusCheckImageCache = NSCache<NSString, UIImage>()

private func bubbleStatusCheckImage(double: Bool, color: UIColor) -> UIImage? {
  // Colour identity is not stable across appearance changes, so key on the components.
  // A colour that cannot report them (pattern, unusual space) skips the cache entirely
  // rather than collide with every other one.
  var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
  guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else {
    return bubbleStatusCheckImageUncached(double: double, color: color)
  }
  let cacheKey = String(
    format: "%@|%.3f,%.3f,%.3f,%.3f", double ? "d" : "s", r, g, b, a) as NSString
  if let cached = bubbleStatusCheckImageCache.object(forKey: cacheKey) { return cached }
  let image = bubbleStatusCheckImageUncached(double: double, color: color)
  if let image { bubbleStatusCheckImageCache.setObject(image, forKey: cacheKey) }
  return image
}

private func bubbleStatusCheckImageUncached(double: Bool, color: UIColor) -> UIImage? {
  let size = CGSize(width: bubbleStatusSlotWidth, height: bubbleStatusSlotHeight)
  let renderer = UIGraphicsImageRenderer(size: size)
  return renderer.image { ctx in
    // Match the Home receipt's ~7.5pt visual height and stroke weight. Keep the existing
    // 17x14 metadata slot so bubble width, timestamp placement, and wrapping stay stable.
    let scale: CGFloat = 0.82
    let baseX: CGFloat = -1.34
    let baseY = (size.height - (24.0 * scale)) * 0.5

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: baseX + x * scale, y: baseY + y * scale)
    }

    color.setStroke()

    let firstPath = UIBezierPath()
    if double {
      firstPath.move(to: point(4.0, 12.9))
      firstPath.addLine(to: point(7.14286, 16.5))
      firstPath.addLine(to: point(15.0, 7.5))
    } else {
      firstPath.move(to: point(4.0, 12.0))
      firstPath.addLine(to: point(8.94975, 16.9497))
      firstPath.addLine(to: point(19.5572, 6.34326))
    }
    // Heavier strokes so the double-tick reads clearly at this small size (was 1.5/2.0).
    firstPath.lineWidth = (double ? 1.5 : 1.7) * scale
    firstPath.lineCapStyle = .round
    firstPath.lineJoinStyle = .round
    firstPath.stroke()

    if double {
      let secondPath = UIBezierPath()
      secondPath.move(to: point(20.0, 7.5625))
      secondPath.addLine(to: point(11.4283, 16.5625))
      secondPath.addLine(to: point(11.0, 16.0))
      secondPath.lineWidth = 1.5 * scale
      secondPath.lineCapStyle = .round
      secondPath.lineJoinStyle = .round
      secondPath.stroke()
    }
    ctx.cgContext.flush()
  }.withRenderingMode(.alwaysOriginal)
}

struct ChatMessageBubbleLayoutMetrics {
  let bubbleWidth: CGFloat
  let bubbleHeight: CGFloat
  let messageWidth: CGFloat
  let textHeight: CGFloat
  let bodyHeight: CGFloat
  let metaWidth: CGFloat
  let contentWidth: CGFloat
  let mediaHeight: CGFloat
  let isMediaLayout: Bool
  let inlineAttachmentHeight: CGFloat
  let hasInlineAttachment: Bool
  let replyPreviewHeight: CGFloat
  let hasReplyPreview: Bool
  let previewHeight: CGFloat
  let hasLinkPreview: Bool
  let usesBottomMetaLayout: Bool
  let usesRichTextLayout: Bool
  // True only for a compact "thinking" agent turn (loader-only, no steps / text yet):
  // the bubble hugs the shimmer line and is centered in the row instead of stretched to
  // the full agent width. Defaulted so every existing call site is unaffected.
  var agentTurnCentered: Bool = false
  // Tall-content collapse — one shared rule for user text, agent text and settled
  // agent-turn bubbles. `tallToggleVisible` means ChatListView should host an outer
  // glass expand/collapse chip for this row; `tallCollapsed` means the content is
  // currently capped to `tallBubbleCollapsedContentHeight`.
  // `tallOuterToggleReserve` is leftover from the old bottom-chip layout (always 0 —
  // the chip now sits on the bubble's top corner via ChatListView overlay).
  var tallToggleVisible: Bool = false
  var tallCollapsed: Bool = false
  var tallOuterToggleReserve: CGFloat = 0.0
  /// This height is a GUESS: the media's aspect ratio was unknown at measure time, so the
  /// bubble was sized by the square fallback and WILL change once the image resolves. The
  /// list uses this to mark the cached height provisional — never persist it to disk, and
  /// re-measure it the moment the real aspect is known.
  var mediaAspectWasUnknown: Bool = false
}

private struct ChatBubbleMetaWidths {
  let edited: CGFloat
  let pinned: CGFloat
  let views: CGFloat
  let timestamp: CGFloat
  let total: CGFloat
}

private let reactionChipHeight: CGFloat = 24.0
private let reactionChipGap: CGFloat = 4.0
private let reactionChipRowGap: CGFloat = 4.0
private let reactionStripTopGap: CGFloat = 4.0
private let reactionStripBottomInset: CGFloat = 6.0
private let reactionEmojiFont = UIFont.systemFont(ofSize: 14.0)
private let reactionCountFont = UIFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .semibold)

/// Height a reaction strip adds to a bubble: the strip and its gap, less the bottom
/// padding it already sits inside (the strip is laid out `reactionStripBottomInset` up).
private func reactionStripHeightOffset(_ size: CGSize, bottomPadding: CGFloat) -> CGFloat {
  guard size.height > 0.0 else { return 0.0 }
  return size.height + reactionStripTopGap + max(0.0, reactionStripBottomInset - bottomPadding)
}

private func compactEngagementCount(_ count: Int) -> String {
  if count >= 1_000_000 {
    let value = String(format: "%.1f", Double(count) / 1_000_000.0)
    return (value.hasSuffix(".0") ? String(value.dropLast(2)) : value) + "M"
  }
  if count >= 1_000 {
    let value = String(format: "%.1f", Double(count) / 1_000.0)
    return (value.hasSuffix(".0") ? String(value.dropLast(2)) : value) + "K"
  }
  return String(count)
}

private func reactionChipWidth(_ reaction: ChatListRow.Reaction, showsCount: Bool) -> CGFloat {
  let emoji = ceil((reaction.emoji as NSString).size(withAttributes: [.font: reactionEmojiFont]).width)
  guard showsCount else { return max(36.0, emoji + 18.0) }
  let count = ceil((compactEngagementCount(reaction.count) as NSString).size(
    withAttributes: [.font: reactionCountFont]).width)
  return max(42.0, emoji + count + 21.0)
}

private func reactionStripMeasuredSize(
  _ reactions: [ChatListRow.Reaction], maxWidth: CGFloat, showsCount: Bool
) -> CGSize {
  guard !reactions.isEmpty, maxWidth > 0 else { return .zero }
  var rowWidth: CGFloat = 0.0
  var widest: CGFloat = 0.0
  var rows = 1
  for reaction in reactions {
    let width = min(maxWidth, reactionChipWidth(reaction, showsCount: showsCount))
    let proposed = rowWidth == 0.0 ? width : rowWidth + reactionChipGap + width
    if proposed > maxWidth, rowWidth > 0.0 {
      widest = max(widest, rowWidth)
      rowWidth = width
      rows += 1
    } else {
      rowWidth = proposed
    }
  }
  widest = max(widest, rowWidth)
  let height = CGFloat(rows) * reactionChipHeight + CGFloat(rows - 1) * reactionChipRowGap
  return CGSize(width: ceil(widest), height: height)
}

private final class ChatRollingCounterLabel: UILabel {
  func setCounterText(_ value: String, animated: Bool) {
    guard text != value else { return }
    let previous = text
    text = value
    guard animated, previous != nil, window != nil, let host = superview else { return }

    let departing = UILabel(frame: convert(bounds, to: host))
    departing.font = font
    departing.textAlignment = textAlignment
    departing.textColor = textColor
    departing.text = previous
    host.addSubview(departing)
    alpha = 0.0
    transform = CGAffineTransform(translationX: 0.0, y: 7.0).scaledBy(x: 0.92, y: 0.92)
    UIView.animate(
      withDuration: 0.28, delay: 0.0, usingSpringWithDamping: 0.82,
      initialSpringVelocity: 0.25, options: [.allowUserInteraction, .beginFromCurrentState]
    ) {
      departing.alpha = 0.0
      departing.transform = CGAffineTransform(translationX: 0.0, y: -7.0).scaledBy(x: 0.92, y: 0.92)
      self.alpha = 1.0
      self.transform = .identity
    } completion: { _ in
      departing.removeFromSuperview()
    }
  }
}

private final class ChatReactionChipView: UIView {
  let emojiLabel = UILabel()
  let countLabel = ChatRollingCounterLabel()
  var onHold: ((String, CGPoint) -> Void)?
  var onTap: ((String) -> Void)?
  private var emoji = ""
  private var revealFallback: DispatchWorkItem?

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerCurve = .continuous
    layer.borderWidth = 1.0 / UIScreen.main.scale
    clipsToBounds = true
    emojiLabel.font = reactionEmojiFont
    emojiLabel.textAlignment = .center
    countLabel.font = reactionCountFont
    countLabel.textAlignment = .center
    addSubview(emojiLabel)
    addSubview(countLabel)
    let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
    hold.minimumPressDuration = 0.32
    addGestureRecognizer(hold)
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    tap.require(toFail: hold)
    addGestureRecognizer(tap)
  }

  required init?(coder: NSCoder) { nil }

  func apply(
    reaction: ChatListRow.Reaction, appearance: ChatListAppearance, isMe: Bool,
    showsCount: Bool, hidesEmoji: Bool, animated: Bool
  ) {
    emoji = reaction.emoji
    emojiLabel.text = reaction.emoji
    emojiLabel.isHidden = hidesEmoji
    alpha = hidesEmoji ? 0.0 : 1.0
    // A flight that never lands (cell recycled, window gone) must not leave the chip
    // invisible for the rest of the session.
    revealFallback?.cancel()
    revealFallback = nil
    if hidesEmoji {
      let reveal = DispatchWorkItem { [weak self] in
        guard let self, self.alpha < 1.0 else { return }
        self.emojiLabel.isHidden = false
        self.alpha = 1.0
      }
      revealFallback = reveal
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: reveal)
    }
    countLabel.isHidden = !showsCount
    // Own bubbles: the pill takes the message text colour, so it tracks the theme.
    let outgoingInk = appearance.textColorMe
    let outgoingPlate = appearance.bubbleMeGradient.first ?? appearance.accent
    countLabel.textColor =
      reaction.isSelected
      ? appearance.accent
      : (isMe ? outgoingPlate : UIColor.white.withAlphaComponent(0.86))
    countLabel.setCounterText(compactEngagementCount(reaction.count), animated: animated)
    backgroundColor =
      isMe
      ? outgoingInk
      : (reaction.isSelected
        ? appearance.accent.withAlphaComponent(appearance.isDark ? 0.36 : 0.25)
        : UIColor(white: 0.0, alpha: 0.16))
    layer.borderColor =
      isMe
      ? UIColor.clear.cgColor
      : (reaction.isSelected ? appearance.accent : UIColor.white)
        .withAlphaComponent(reaction.isSelected ? 0.58 : 0.16).cgColor
  }

  @objc private func handleTap() {
    guard !emoji.isEmpty else { return }
    onTap?(emoji)
  }

  @objc private func handleHold(_ gesture: UILongPressGestureRecognizer) {
    guard gesture.state == .began, !emoji.isEmpty, let window else { return }
    let point = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: window)
    onHold?(emoji, point)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = bounds.height * 0.5
    let emojiWidth = ceil(emojiLabel.intrinsicContentSize.width)
    let countWidth = countLabel.isHidden ? 0.0 : ceil(countLabel.intrinsicContentSize.width)
    let spacing = countLabel.isHidden ? 0.0 : 5.0
    let contentWidth = emojiWidth + spacing + countWidth
    let startX = floor((bounds.width - contentWidth) * 0.5)
    emojiLabel.frame = CGRect(x: startX, y: 0.0, width: emojiWidth, height: bounds.height)
    countLabel.frame = CGRect(
      x: emojiLabel.frame.maxX + spacing, y: 0.0, width: countWidth, height: bounds.height)
  }

  func playLandingPulse() {
    alpha = 1.0
    layer.removeAnimation(forKey: "reactionLanding")
    let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
    pulse.values = [1.0, 1.24, 0.96, 1.0]
    pulse.keyTimes = [0.0, 0.34, 0.72, 1.0]
    pulse.duration = 0.42
    pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
    layer.add(pulse, forKey: "reactionLanding")
  }
}

private final class ChatReactionStripView: UIView {
  private var chips: [String: ChatReactionChipView] = [:]
  private var reactions: [ChatListRow.Reaction] = []
  private var animatesNextLayout = false
  private var showsCount = true
  var onHold: ((String, CGPoint) -> Void)?
  var onTap: ((String) -> Void)?

  func configure(
    reactions: [ChatListRow.Reaction], appearance: ChatListAppearance, isMe: Bool,
    chatId: String, messageId: String, showsCount: Bool, animated: Bool
  ) {
    self.reactions = reactions
    self.showsCount = showsCount
    animatesNextLayout = animated
    let live = Set(reactions.map(\.emoji))
    let stale = chips.keys.filter { !live.contains($0) }
    for emoji in stale {
      chips.removeValue(forKey: emoji)?.removeFromSuperview()
    }
    for reaction in reactions {
      let chip = chips[reaction.emoji] ?? ChatReactionChipView()
      if chip.superview == nil { addSubview(chip) }
      chips[reaction.emoji] = chip
      chip.onHold = { [weak self] emoji, point in self?.onHold?(emoji, point) }
      chip.onTap = { [weak self] emoji in self?.onTap?(emoji) }
      let hidesEmoji = ChatReactionTransitionCoordinator.shared.isFlying(
        chatId: chatId, messageId: messageId, emoji: reaction.emoji)
      chip.apply(
        reaction: reaction, appearance: appearance, isMe: isMe, showsCount: showsCount,
        hidesEmoji: hidesEmoji, animated: animated)
    }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let shouldAnimate = animatesNextLayout && window != nil
    animatesNextLayout = false
    var x: CGFloat = 0.0
    var y: CGFloat = 0.0
    for reaction in reactions {
      guard let chip = chips[reaction.emoji] else { continue }
      let width = min(bounds.width, reactionChipWidth(reaction, showsCount: showsCount))
      if x > 0.0, x + width > bounds.width {
        x = 0.0
        y += reactionChipHeight + reactionChipRowGap
      }
      let frame = pixelAlignedRect(CGRect(x: x, y: y, width: width, height: reactionChipHeight))
      if shouldAnimate, chip.bounds.width > 0.0, chip.frame != frame {
        UIView.animate(
          withDuration: 0.28, delay: 0.0, usingSpringWithDamping: 0.84,
          initialSpringVelocity: 0.2, options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
          chip.frame = frame
        }
      } else {
        chip.frame = frame
      }
      x += width + reactionChipGap
    }
  }

  var firstChipCenter: CGPoint? {
    guard let first = reactions.first, let chip = chips[first.emoji] else { return nil }
    return CGPoint(x: chip.frame.midX, y: chip.frame.midY)
  }

  func landingCenter(for emoji: String, in view: UIView) -> CGPoint? {
    guard let chip = chips[emoji], chip.window != nil else { return nil }
    return chip.convert(CGPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: view)
  }

  func playLandingPulse(for emoji: String) {
    chips[emoji]?.emojiLabel.isHidden = false
    chips[emoji]?.playLandingPulse()
  }
}

/// Per-row expand/streaming state for the inline agent-turn bubble, owned by
/// `ChatListView` (see its `agentTurn*` dictionaries — a `UICollectionViewCell` is
/// reused across scroll and can't hold this itself). Threaded into
/// `measureMessageBubbleLayout` so a pre-layout height estimate (before any cell
/// exists) matches what the cell will actually render.
struct AgentTurnBubbleState: Equatable {
  var isProgressExpanded: Bool = false
  var isRuntimeExpanded: Bool = false
  var expandedStepIds: Set<String> = []
  var streamingStartDate: Date? = nil
  // Tall-bubble expand state. Despite living in the agent-turn struct (it rides the
  // existing measure/configure threading), this applies to ANY tall bubble — user
  // text included — via the shared tall-content collapse in measureMessageBubbleLayout.
  var tallExpanded: Bool = false
  var videoNoteExpanded: Bool = false
}

private func measuredTextWidth(_ text: String, font: UIFont) -> CGFloat {
  ceil((text as NSString).size(withAttributes: [.font: font]).width)
}

private func colorLuminance(_ color: UIColor) -> CGFloat {
  var red: CGFloat = 0.0
  var green: CGFloat = 0.0
  var blue: CGFloat = 0.0
  var alpha: CGFloat = 0.0
  if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
    return (0.299 * red) + (0.587 * green) + (0.114 * blue)
  }

  var white: CGFloat = 0.0
  if color.getWhite(&white, alpha: &alpha) {
    return white
  }

  return 0.5
}

private func contrastingMediaForeground(for color: UIColor) -> UIColor {
  colorLuminance(color) > 0.68
    ? UIColor(white: 0.08, alpha: 0.96)
    : UIColor(white: 1.0, alpha: 0.98)
}


private func formatBubbleDuration(seconds: Double?) -> String {
  guard let seconds, seconds.isFinite, seconds > 0 else {
    return "0:00"
  }
  let total = max(0, Int(round(seconds)))
  let minutes = total / 60
  let secs = total % 60
  return String(format: "%d:%02d", minutes, secs)
}

private func formatBubblePlaybackTimer(current: Double?, duration: Double?) -> String {
  let totalSeconds = max(0.0, duration ?? 0.0)
  let currentSeconds = max(0.0, current ?? 0.0)
  let remainingSeconds = totalSeconds > 0.0 ? max(0.0, totalSeconds - currentSeconds) : 0.0
  return formatBubbleDuration(seconds: remainingSeconds)
}

private func formatMediaByteSize(_ bytes: Int64) -> String {
  let kb = Double(bytes) / 1024.0
  if kb < 1.0 { return "\(bytes) B" }
  let mb = kb / 1024.0
  if mb < 1.0 { return String(format: "%.0f KB", kb) }
  let gb = mb / 1024.0
  if gb < 1.0 { return String(format: "%.1f MB", mb) }
  return String(format: "%.2f GB", gb)
}

/// Byte captions for live download/upload chrome (`ByteCountFormatter`, `.file`).
private let chatDownloadByteCountFormatter: ByteCountFormatter = {
  let formatter = ByteCountFormatter()
  formatter.countStyle = .file
  formatter.allowsNonnumericFormatting = false
  return formatter
}()

private func formatDownloadByteCount(_ bytes: Int64) -> String {
  chatDownloadByteCountFormatter.string(fromByteCount: bytes)
}

private let chatTransferProgressQuantizationStep: CGFloat = 0.01
private let chatTransferProgressAnimationThreshold: CGFloat = 0.006

private func quantizedTransferProgress(_ progress: CGFloat?, minimum: CGFloat) -> CGFloat? {
  guard let progress, progress.isFinite else { return nil }
  let clamped = max(minimum, min(1.0, progress))
  let quantized =
    (clamped / chatTransferProgressQuantizationStep).rounded() * chatTransferProgressQuantizationStep
  return max(minimum, min(1.0, quantized))
}

/// Agent `type: music` (and other non-voice audio) rows: compact playable music cell
/// (cover on the play plate + title/artist), NOT the tall Telegram link-preview card.
/// SoundCloud/YouTube *text* URLs still use `BubbleLinkPreviewView` music-card mode.
private func usesAudioMetadataVoiceLayout(_ row: ChatListRow) -> Bool {
  row.visualKind == .voice && row.messageType.lowercased() != "voice"
}

private func normalizedChatAudioId(_ value: String?) -> String? {
  guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
    return nil
  }
  return trimmed
}

private func resolvedAudioVoiceTitle(_ row: ChatListRow) -> String {
  let rawTitle =
    row.fileName?.trimmingCharacters(in: .whitespacesAndNewlines)
    ?? row.text.trimmingCharacters(in: .whitespacesAndNewlines)
  let sanitizedTitle = (rawTitle as NSString).lastPathComponent
  let displayTitle = (sanitizedTitle as NSString).deletingPathExtension
  if displayTitle.isEmpty || displayTitle.count < 2 {
    let lowerType = row.messageType.lowercased()
    if lowerType == "mp3" { return "MP3" }
    if lowerType == "music" { return "Music" }
    if row.fileName?.lowercased().hasSuffix(".mp3") ?? false { return "MP3" }
    return "Audio"
  }
  return displayTitle
}

private func resolvedAudioVoiceStaticDetail(_ row: ChatListRow) -> String {
  if usesAudioMetadataVoiceLayout(row) {
    // Telegram-style third line: artist, else duration. The artist can also come from the
    // file's own tags for a track sent before the envelope carried them.
    if let artist = row.musicArtist?.trimmingCharacters(in: .whitespacesAndNewlines),
      !artist.isEmpty
    {
      return artist
    }
    if let messageId = row.messageId, let recovered = chatRecoveredAudioTags.artist(for: messageId) {
      return recovered
    }
    if let duration = row.duration, duration.isFinite, duration > 0 {
      return formatBubbleDuration(seconds: duration)
    }
    return row.musicSource ?? "Music"
  }
  var components: [String] = []
  if let duration = row.duration, duration.isFinite, duration > 0 {
    components.append(formatBubbleDuration(seconds: duration))
  }
  if components.isEmpty {
    let lowerType = row.messageType.lowercased()
    if lowerType == "mp3" { return "MP3" }
    if lowerType == "music" { return "Music" }
    return "Audio"
  }
  return components.joined(separator: " • ")
}

private func resolvedMusicSourceLabel(_ row: ChatListRow) -> String {
  if let source = row.musicSource?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty {
    return source
  }
  let lowerType = row.messageType.lowercased()
  if lowerType == "music" || lowerType == "mp3" || lowerType == "audio" { return "Music" }
  return "Audio"
}

/// Telegram music card text stack under the artwork: Source / Title / Artist.
/// Prefer the cover-card labels over the compact voice "duration •" chrome.
private func musicCardTextStack(for row: ChatListRow) -> (source: String, title: String, artist: String?) {
  let source = resolvedMusicSourceLabel(row)
  let title = resolvedAudioVoiceTitle(row)
  let artist = row.musicArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
  let resolvedArtist = (artist?.isEmpty == false) ? artist : nil
  return (source, title, resolvedArtist)
}

private func trimmedBubbleText(_ row: ChatListRow) -> String {
  row.text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func hasMediaCaptionLayout(_ row: ChatListRow) -> Bool {
  guard row.kind == .message else { return false }
  guard row.visualKind == .media || row.visualKind == .video || row.visualKind == .videoNote
    || row.visualKind == .document
  else {
    return false
  }
  return !trimmedBubbleText(row).isEmpty
}

private func agentResponseInProgress(_ row: ChatListRow) -> Bool {
  row.isAgentMessage
    && (row.isStreamingText
      || row.messageType == "typing"
      || row.messageType == "agent_progress_tree")
}

/// The narrower "nothing to read yet" subset of `agentResponseInProgress`: typing dots,
/// the progress-tree placeholder, or a streaming bubble that hasn't produced text.
/// Only these phases hide the timestamp (an empty "Thinking…" bubble must not balloon
/// around a time reserve). Once real streamed text is flowing, the bubble reserves AND
/// shows the meta exactly like its settled replacement — otherwise the stream→settle
/// swap re-measures with the timestamp and re-wraps the last line (the "content shifts
/// to different padding when the turn finishes" jump).
private func agentResponsePlaceholder(_ row: ChatListRow) -> Bool {
  row.isAgentMessage
    && (row.messageType == "typing"
      || row.messageType == "agent_progress_tree"
      || (row.isStreamingText && trimmedBubbleText(row).isEmpty))
}

/// A supervisor team-run LEAD row: the single visible cell of an `@team` run (workers
/// are suppressed under the hood). It renders the structured team feed in its bubble —
/// including in GROUPS: the general group exclusion in `bubbleUsesAgentTurnContent`
/// exists because multiple agents' streams would interleave into one messy feed, but a
/// supervisor run has exactly ONE visible cell, so the concern doesn't apply.
func bubbleRendersTeamRun(_ row: ChatListRow) -> Bool {
  guard row.isAgentMessage, let runtime = row.agentRuntime,
    let teamRunId = runtime.teamRunId, !teamRunId.isEmpty
  else { return false }
  return runtime.teamMode == "supervisor" || runtime.teamMode == "group_supervisor"
    || !runtime.teamWorkersStatus.isEmpty
}

/// Whether this row renders its full interleaved step/narration/diff feed directly in
/// the chat bubble (via `VibeAgentTurnContentView`). True for any 1:1 agent turn — a
/// group/multi-agent row (`row.isGroupOrChannel`) instead defers to the full-page agent
/// runtime view so multiple agents' output doesn't interleave into one messy feed; no
/// live route sets that flag for a bridge-agent row today, so this is effectively always
/// true in practice until group-agent support ships. Exception: a supervisor team-run
/// lead row (see `bubbleRendersTeamRun`) uses this path in groups too — it's the run's
/// only visible cell and needs the structured worker feed instead of a churning text
/// bubble.
// Internal (not private) so ChatListView's setRows can route streaming agent-turn reloads
// through `reconfigureItems` (persist the cell + its reusable live feed) instead of
// `reloadItems` (recreate → re-fade the whole narration every chunk).
/// A native (built-in "Vibe AI") PLAIN conversational agent turn: no tool feed, no runtime
/// card, no actions, and not a bridge/stream/lan session row. Its SETTLED form renders as an
/// ordinary text bubble (hugs its text, ~34pt); keeping only its STREAMING form on the
/// agent-turn path (via `isStreamingText`) — which floors the bubble at 44pt to reserve the
/// loader/meta strip — made the turn visibly shrink + shift the instant it settled (the
/// ~working-cell-height empty gap the user reported: [LayoutShift] Δ (44→34) + [CellFit]
/// OVERFLOW at `finishStreaming`). Routing BOTH phases through the same plain bubble makes
/// streaming==settled by construction. Bridge (Claude/Codex) turns never match (they carry a
/// runtime/progress feed or a "bridge-" id) so they stay on the agent-turn path, and a native
/// turn WITH tools keeps it too (its progress nodes are non-empty).
func agentTurnRowIsNativePlainProse(_ row: ChatListRow) -> Bool {
  guard row.isAgentMessage,
    row.agentRuntime == nil,
    row.agentProgressNodes.isEmpty,
    (row.agentActionsEnc?.isEmpty ?? true),
    row.messageType != "agent_progress_tree"
  else { return false }
  let id = row.messageId ?? ""
  return !id.hasPrefix("bridge-") && !id.hasPrefix("stream-") && !id.hasPrefix("lan-")
}

func bubbleUsesAgentTurnContent(_ row: ChatListRow) -> Bool {
  // Native plain conversational turns render as an ordinary text bubble, live AND settled,
  // so nothing re-measures at settle. (See `agentTurnRowIsNativePlainProse`.)
  if agentTurnRowIsNativePlainProse(row) { return false }
  return (!row.isGroupOrChannel || bubbleRendersTeamRun(row))
    && row.kind == .message
    && row.visualKind == .text
    && row.isAgentMessage
    && agentSystemDividerText(for: row) == nil
    && agentErrorNoticeText(for: row) == nil
    && (row.isStreamingText
      || row.messageType == "agent_progress_tree"
      || !row.agentProgressNodes.isEmpty
      || row.agentRuntime != nil
      || (row.agentActionsEnc?.isEmpty == false)
      // Session-ingested bridge rows (ids "bridge-<sessionId>-…") stay on this path
      // even when a turn carried no runtime card / progress feed (a plain no-tool
      // answer). Otherwise the LIVE version of the turn renders via the agent-turn
      // layout and its settled replacement falls back to the default text bubble —
      // a few points of measurement drift (meta reserve, body renderer) that showed
      // up as the cell subtly shifting and re-padding seconds after it landed.
      || (row.messageId ?? "").hasPrefix("bridge-"))
}

/// A Claude/Codex control/context event that must render as a centered, muted mid-chat
/// divider (styled like a day/time separator) rather than a user or assistant bubble.
/// Covers the `/compact` summary ("Context compacted") and the synthetic
/// "[Request interrupted by user]" turn Claude Code inserts when a run is stopped — both
/// otherwise leak into the transcript as ordinary message bubbles (the interrupt lands as
/// a right-side USER bubble because Claude records it as a user turn). Mirrors the
/// full-page agent view's classification in `VibeAgentKitMap.chatMessage(from:)`
/// (`isCompactionSummary` / `systemDividerText`) so both surfaces treat these the same.
/// Returns the short divider label, or nil for an ordinary row.
func agentSystemDividerText(for row: ChatListRow) -> String? {
  guard row.kind == .message else { return nil }
  if row.isAgentMessage && row.agentMsgKind == "summary" {
    return "Context compacted"
  }
  let body = (row.isAgentMessage ? (row.plainContent ?? row.text) : row.text)
    .trimmingCharacters(in: .whitespacesAndNewlines)

  // Group membership notices — centered transparent text (not a bubble).
  if let notice = groupSystemNoticeText(for: row, body: body) {
    return notice
  }

  if body.isEmpty {
    let runtimeStatus = row.agentRuntime?.status
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    if ["stopped", "cancelled", "canceled", "interrupted"].contains(runtimeStatus) {
      return "Interrupted"
    }
    return nil
  }
  if body == "[Request interrupted by user]"
    || body.localizedCaseInsensitiveContains("request interrupted by user")
  {
    return "Interrupted"
  }
  return nil
}

/// A friendly, human-readable notice for an agent turn the server marked as an error
/// (`isError`). Production apps never surface a raw "API error: 400" / "AI request
/// failed." string as an ordinary assistant bubble — it reads like the agent *said*
/// the error, and the in-cell retry chrome makes the transcript feel broken. Instead
/// an errored turn renders as a centered, muted mid-chat notice (styled like the
/// day/interrupt divider, but with a warning glyph and a tappable "Try again") so the
/// list stays clean and the failure is legible at the point it happened. Returns the
/// short human message, or nil for any non-error row.
func agentErrorNoticeText(for row: ChatListRow) -> String? {
  guard row.kind == .message,
    row.isAgentMessage,
    row.isAgentError,
    !row.isStreamingText
  else { return nil }
  let raw = (row.plainContent ?? row.text).trimmingCharacters(in: .whitespacesAndNewlines)
  return humanizedAgentErrorMessage(raw)
}

/// Maps a raw provider/transport error string to calm, human copy. Never leaks status
/// codes or internal phrasing — the raw text is only inspected to pick the closest
/// friendly sentence.
func humanizedAgentErrorMessage(_ raw: String) -> String {
  let lower = raw.lowercased()
  if lower.contains("429") || lower.contains("rate limit") || lower.contains("overloaded")
    || lower.contains("capacity") || lower.contains("quota")
    || lower.contains("usage limit") || lower.contains("too many requests")
  {
    return "The assistant is busy right now"
  }
  if lower.contains("timeout") || lower.contains("timed out") {
    return "That took too long to answer"
  }
  if lower.contains("network") || lower.contains("connection")
    || lower.contains("offline") || lower.contains("unreachable")
  {
    return "Couldn't reach the assistant"
  }
  // API error: 4xx/5xx, "AI request failed.", parse failures, and anything unknown all
  // collapse to one calm default — the raw detail lives in logs, not the transcript.
  return "Something went wrong"
}

/// Formats "Alice added Bob", "Carol left the group", "Dave joined the group",
/// or a sender-declared decision notice.
/// Prefers the structured `metadata.service` node so join/leave/decision events
/// never depend on English body prose. Falls back to string sniffing for
/// messages already in the database that predate the service node.
func groupSystemNoticeText(for row: ChatListRow, body: String) -> String? {
  // Canonical path: structured service node (membership, decision, future kinds).
  if let service = row.serviceMessage {
    return service.displayText
  }

  let type = row.messageType.lowercased()
  let isSystemType =
    type == "system"
    || type == "group_event"
    || type == "group_system"
    || type == "system_message"

  // Metadata may ride on the raw message via plainContent JSON or body prefix.
  // Prefer explicit body when the server already composed a notice.
  if isSystemType, !body.isEmpty {
    return body
  }

  // Fallback for history that only has freeform body text (pre-service-node).
  // Do not delete: existing rows never gained a `metadata.service` payload.
  let lower = body.lowercased()
  if lower.contains(" added ") && (lower.contains(" to the group") || lower.contains(" to group")) {
    return body
  }
  if lower.contains(" left the group") || lower.hasSuffix(" left") {
    return body
  }
  if lower.contains(" joined the group") || lower.hasSuffix(" joined") {
    return body
  }
  if lower.contains(" removed ") && lower.contains(" from the group") {
    return body
  }
  return nil
}

/// Risk class of a pending approval (`external_effect`, `credential`, `write_local`, …).
/// Rides the socket frame only, so a cold open shows the card without a chip.
func serviceDecisionRisk(for row: ChatListRow) -> String? {
  guard let service = row.serviceMessage, service.hasLiveActions else { return nil }
  if let meta = ChatEngine.shared.agentApprovalMeta(messageId: row.messageId), !meta.risk.isEmpty {
    return meta.risk
  }
  guard let risk = service.risk, !risk.isEmpty else { return nil }
  return risk
}

/// The exact command / URL / path the approval is about: host+path for `browser_open`,
/// the raw command otherwise. Falls back to the decision node's second plain part.
func serviceDecisionDetailText(for row: ChatListRow) -> String? {
  guard let service = row.serviceMessage, service.hasLiveActions else { return nil }
  let meta = ChatEngine.shared.agentApprovalMeta(messageId: row.messageId)
  let raw = (meta.map { $0.detail } ?? "").isEmpty
    ? (service.detailText ?? "") : (meta?.detail ?? "")
  let detail = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !detail.isEmpty else { return nil }
  guard (meta?.tool ?? "") == "browser_open", let url = URL(string: detail),
    let host = url.host
  else { return detail }
  let stripped = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  return url.path.isEmpty || url.path == "/" ? stripped : stripped + url.path
}

/// Extra height under a centred service notice when live decision actions are present:
/// the risk chip + monospaced detail block, then the action bar.
func serviceDecisionActionsHeight(for row: ChatListRow) -> CGFloat {
  guard let service = row.serviceMessage, service.hasLiveActions else { return 0 }
  return 40.0
    + ChatServiceDecisionCardView.height(
      risk: serviceDecisionRisk(for: row), detail: serviceDecisionDetailText(for: row))
}

private func bubbleMetaWidths(for row: ChatListRow) -> ChatBubbleMetaWidths {
  if row.messageType == "agent_progress"
    || usesTransparentAgentStreamingLayout(row)
    || agentResponsePlaceholder(row)
    || bubbleUsesAgentTurnContent(row)
  {
    return ChatBubbleMetaWidths(edited: 0.0, pinned: 0.0, views: 0.0, timestamp: 0.0, total: 0.0)
  }

  var items: [CGFloat] = []
  let editedWidth = measuredTextWidth("edited", font: bubbleMetaFont)
  let pinnedWidth = measuredTextWidth("pinned", font: bubbleMetaFont)
  let viewTextWidth = row.viewCount.map {
    measuredTextWidth(compactEngagementCount($0), font: bubbleMetaFont)
  } ?? 0.0
  let viewsWidth = viewTextWidth > 0.0 ? 12.0 + 2.0 + viewTextWidth : 0.0
  let timestampWidth = measuredTextWidth(row.timestamp, font: bubbleMetaFont)

  if viewsWidth > 0.0 {
    items.append(viewsWidth)
  }
  if row.isEdited {
    items.append(editedWidth)
  }
  if row.isPinned {
    items.append(pinnedWidth)
  }
  items.append(timestampWidth)
  items.append(bubbleStatusSlotWidth)

  let gapWidth = CGFloat(max(0, items.count - 1)) * bubbleMetaItemGap
  let total = items.reduce(0.0, +) + gapWidth
  return ChatBubbleMetaWidths(
    edited: editedWidth,
    pinned: pinnedWidth,
    views: viewsWidth,
    timestamp: timestampWidth,
    total: total
  )
}

private let inlineAttachmentHeight: CGFloat = 48.0
private let inlineAttachmentSpacing: CGFloat = 8.0
private let bubbleReplyPreviewHeight: CGFloat = 36.0
private let bubbleReplyPreviewSpacing: CGFloat = 6.0
private let bubbleReplyPreviewMinWidth: CGFloat = 184.0
private let stickerMinDisplaySide: CGFloat = 72.0
private let stickerDefaultDisplaySide: CGFloat = 136.0
private let stickerMaxDisplayWidth: CGFloat = 152.0
private let stickerMaxDisplayHeight: CGFloat = 184.0
private let stickerMetaTopSpacing: CGFloat = 1.0

// ── سلولِ سند ──────────────────────────────────────────────────────────────
// اندازه‌گیریِ حباب و چیدمانِ سلول هر دو به این‌ها نیاز دارند، پس در سطح فایل‌اند.

let documentRowVerticalInset: CGFloat = 9.0
let documentPreviewSide: CGFloat = 62.0
let documentPreviewCornerRadius: CGFloat = 10.0
let documentRowHeight: CGFloat = documentPreviewSide + documentRowVerticalInset * 2.0

/// نامِ نمایشیِ سند.
///
/// روی `row.fileName` تنها تکیه نمی‌کنیم: هم نشانیِ امضاشدهٔ سند
/// (`/api/containers/3/pdf`) و هم نامِ فایلِ کش، جزءِ پایانیِ بی‌پسوند دارند و در
/// سلول به‌صورت «pdf» یا «3» ظاهر می‌شدند. نامی نام است که پسوند داشته باشد.
func chatDocumentDisplayName(_ row: ChatListRow) -> String {
  if let named = chatDocumentFileNameCandidate(row.fileName) { return named }
  if let mediaUrl = row.mediaUrl {
    let component =
      URL(string: mediaUrl)?.lastPathComponent ?? (mediaUrl as NSString).lastPathComponent
    if let named = chatDocumentFileNameCandidate(component.removingPercentEncoding ?? component) {
      return named
    }
  }
  // عنوانِ خودِ پیوست بهتر از یک برچسبِ عمومی است.
  if let title = row.fileName?.trimmingCharacters(in: .whitespacesAndNewlines),
    title.count > 1
  {
    return title
  }
  return chatDocumentTypeLabel(row)
}

private func chatDocumentFileNameCandidate(_ raw: String?) -> String? {
  guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
  else {
    return nil
  }
  let ext = (trimmed as NSString).pathExtension
  let stem = (trimmed as NSString).deletingPathExtension
  // «pdf» پسوند ندارد و «3» ریشه‌ای است بی‌پسوند — هیچ‌کدام نامِ فایل نیستند.
  guard !ext.isEmpty, !stem.isEmpty, ext.count <= 8 else { return nil }
  return trimmed
}

func chatDocumentIsPDF(_ row: ChatListRow) -> Bool {
  if (row.mimeType ?? "").lowercased().contains("pdf") { return true }
  let name = row.fileName ?? row.mediaUrl ?? ""
  return (name as NSString).pathExtension.lowercased() == "pdf"
}

func chatDocumentTypeLabel(_ row: ChatListRow) -> String {
  if chatDocumentIsPDF(row) { return "PDF Document" }
  let mime = (row.mimeType ?? "").lowercased()
  if mime.contains("html") { return "Web Page" }
  if mime.contains("zip") { return "Archive" }
  if mime.contains("csv") || mime.contains("spreadsheet") || mime.contains("excel") {
    return "Spreadsheet"
  }
  if mime.contains("word") || mime.contains("msword") { return "Document" }
  if mime.hasPrefix("text/") { return "Text File" }
  return "File"
}

func chatDocumentGlyphName(_ row: ChatListRow) -> String {
  if chatDocumentIsPDF(row) { return "doc.richtext" }
  let mime = (row.mimeType ?? "").lowercased()
  if mime.contains("html") { return "globe" }
  if mime.contains("zip") { return "doc.zipper" }
  if mime.contains("csv") || mime.contains("spreadsheet") || mime.contains("excel") {
    return "tablecells"
  }
  return "doc"
}

private func hasInlineFileAttachment(_ row: ChatListRow) -> Bool {
  guard row.visualKind == .text else { return false }
  guard let mediaUrl = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
    !mediaUrl.isEmpty
  else {
    return false
  }
  let hasFileNameHint =
    !(row.fileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
  let lowerMediaURL = mediaUrl.lowercased()
  let isAgentDocURL =
    lowerMediaURL.contains("/uploads/agent-docs/")
    || lowerMediaURL.contains("/api/agent/document/")
  if isAgentDocURL {
    return true
  }
  return row.isAgentMessage && (row.messageType == "file" || hasFileNameHint)
}

private func hasInlineRelatedMessages(_ row: ChatListRow) -> Bool {
  guard !row.isEventInboxSummary else { return false }
  return !row.relatedMessageIds.isEmpty
}

private func hasInlineAttachment(_ row: ChatListRow) -> Bool {
  hasInlineRelatedMessages(row) || hasInlineFileAttachment(row)
}

private func hasReplyPreview(_ row: ChatListRow) -> Bool {
  guard row.kind == .message, row.visualKind == .text else { return false }
  guard !row.isEventNotification, !row.hiddenFromTranscript else { return false }
  return row.replyToId != nil
}

private func replyPreviewTitle(for row: ChatListRow) -> String {
  if let title = row.replyPreviewTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
    !title.isEmpty
  {
    return title
  }
  return "Reply"
}

private func replyPreviewText(for row: ChatListRow) -> String {
  if let text = row.replyPreviewText?.trimmingCharacters(in: .whitespacesAndNewlines),
    !text.isEmpty
  {
    return text
  }
  return "Message"
}

private func inlineAttachmentTitle(for row: ChatListRow) -> String {
  if hasInlineRelatedMessages(row) {
    if let title = row.relatedMessagesTitle, !title.isEmpty {
      return title
    }
    return row.relatedMessageIds.count == 1 ? "Related message" : "\(row.relatedMessageIds.count) related messages"
  }
  if let fileName = row.fileName, !fileName.isEmpty {
    return fileName
  }
  return "Document"
}

private func inlineAttachmentSubtitle(for row: ChatListRow) -> String {
  if hasInlineRelatedMessages(row) {
    if let subtitle = row.relatedMessagesSubtitle, !subtitle.isEmpty {
      return subtitle
    }
    return "Tap to review"
  }
  return "Tap to open"
}

private func inlineAttachmentIconName(for row: ChatListRow) -> String {
  hasInlineRelatedMessages(row) ? "list.bullet.rectangle.portrait.fill" : "doc.text.fill"
}

private func isRTL(_ text: String) -> Bool {
  return text.range(of: "[\\u0600-\\u06FF]", options: .regularExpression) != nil
}

private func usesRTLColumnLayout(_ row: ChatListRow) -> Bool {
  guard row.kind == .message, row.visualKind == .text else { return false }
  guard row.messageType != "typing" else { return false }
  // Always stack meta under RTL body (Telegram short Farsi/Arabic): text on top,
  // time below — bubble height grows. Never put time beside RTL on one row.
  return isRTL(row.text)
}

// MARK: - Media natural size

/// A media bubble's height IS its aspect ratio, so a row whose pixel size is unknown cannot be
/// sized at all: `measureMessageBubbleLayout` falls back to a SQUARE (`mediaHeight =
/// targetWidth`), the cell then decodes the image, reports the real size, and
/// `handleResolvedMediaSize` re-measures the row — moving everything below it. `[CellFit]
/// slot-repair … slack=252` was exactly that: a wide, short photo sized as a ~330pt square and
/// corrected to ~84 a beat after the chat opened.
///
/// The pixel size is a property of the MEDIA, not of the layout, so it is remembered across
/// launches and keyed on stable identity — never the signed URL, which is re-minted on every
/// fetch. It also outlives a `bubbleLayoutRevision` bump, unlike the persisted heights. With it
/// on disk the first measure after a cold launch is already exact and nothing corrects.
final class ChatMediaNaturalSizeStore {
  static let shared = ChatMediaNaturalSizeStore()

  private let lock = NSLock()
  private var sizes: [String: CGSize] = [:]
  private var insertionOrder: [String] = []
  private var loaded = false
  private var savePending = false
  /// Bounded: a few thousand entries is a handful of KB, and dropping the oldest keeps a heavy
  /// library from growing the file without limit.
  private static let capacity = 6000
  private static let trimTo = 4500
  private let queue = DispatchQueue(label: "vibe.media.natural-size", qos: .utility)
  private lazy var fileURL: URL = vibeDurableMediaCacheRoot()
    .appendingPathComponent("media-natural-sizes.json", isDirectory: false)

  func size(for identity: String) -> CGSize? {
    guard !identity.isEmpty else { return nil }
    lock.lock()
    loadIfNeededLocked()
    let stored = sizes[identity]
    lock.unlock()
    guard let stored, stored.width > 1.0, stored.height > 1.0 else { return nil }
    return stored
  }

  func record(_ size: CGSize, for identity: String) {
    guard !identity.isEmpty, size.width > 1.0, size.height > 1.0 else { return }
    lock.lock()
    loadIfNeededLocked()
    let existing = sizes[identity]
    if let existing, abs(existing.width - size.width) < 1.0,
      abs(existing.height - size.height) < 1.0
    {
      lock.unlock()
      return
    }
    if existing == nil { insertionOrder.append(identity) }
    sizes[identity] = size
    if insertionOrder.count > Self.capacity {
      let overflow = insertionOrder.count - Self.trimTo
      for key in insertionOrder.prefix(overflow) { sizes.removeValue(forKey: key) }
      insertionOrder.removeFirst(overflow)
    }
    scheduleSaveLocked()
    lock.unlock()
  }

  /// Diagnostics only — `[HeightShift]` prints whether the size was already on disk.
  func contains(_ identity: String) -> Bool { size(for: identity) != nil }

  /// Read the file OFF the main thread at launch. The first lookup happens inside a sizing
  /// pass during the chat open, and that is the one place this must never be a disk read.
  func prewarm() {
    queue.async { [weak self] in
      guard let self else { return }
      self.lock.lock()
      self.loadIfNeededLocked()
      let count = self.sizes.count
      self.lock.unlock()
      // A count of 0 on a launch that has already displayed photos means the store never
      // wrote — the difference between "this media is new" and "the remembering is broken",
      // which `squareMedia=N` alone cannot tell apart.
      NSLog("[HeightShift] natural-size store loaded entries=%d", count)
    }
  }

  private func loadIfNeededLocked() {
    guard !loaded else { return }
    loaded = true
    guard let data = try? Data(contentsOf: fileURL),
      let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [Double]]
    else { return }
    for (identity, pair) in raw where pair.count == 2 && pair[0] > 1.0 && pair[1] > 1.0 {
      sizes[identity] = CGSize(width: pair[0], height: pair[1])
      insertionOrder.append(identity)
    }
  }

  /// Debounced: scrolling a photo-heavy chat records dozens of sizes within a few frames, and
  /// each one is a single small dictionary entry — not worth a write apiece.
  private func scheduleSaveLocked() {
    guard !savePending else { return }
    savePending = true
    queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
      guard let self else { return }
      self.lock.lock()
      self.savePending = false
      let snapshot = self.sizes
      self.lock.unlock()
      var raw: [String: [Double]] = [:]
      raw.reserveCapacity(snapshot.count)
      for (identity, size) in snapshot {
        raw[identity] = [Double(size.width), Double(size.height)]
      }
      guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return }
      try? data.write(to: self.fileURL, options: [.atomic])
    }
  }
}

/// Stable, url-only address for the natural-size store. Deliberately WITHOUT the media key: the
/// pixel size belongs to the media itself, and the same URL always denotes the same media.
func chatMediaNaturalSizeIdentity(_ mediaUrl: String?) -> String? {
  guard let mediaUrl else { return nil }
  let trimmed = mediaUrl.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  return VibeMediaVault.identity(rawURL: trimmed)
}

/// Height/width of the inline blur thumbnail. The thumb ships with the message, is a few
/// hundred bytes, and has the SAME shape as the full media — so a photo the app has never seen
/// can still be mounted at the right shape instead of a square that collapses the moment the
/// download lands. Header-only, so it costs a base64 decode and no bitmap.
func chatMediaThumbnailAspect(_ value: String?) -> CGFloat? {
  guard let value else { return nil }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  let payload: String = {
    if let commaIndex = trimmed.firstIndex(of: ","),
      trimmed[..<commaIndex].contains("base64")
    {
      return String(trimmed[trimmed.index(after: commaIndex)...])
    }
    return trimmed
  }()
  guard
    let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]),
    let source = CGImageSourceCreateWithData(data as CFData, nil),
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
    let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
    let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
    width > 1.0, height > 1.0
  else { return nil }
  return CGFloat(height / width)
}

/// Pixel size from an image file's HEADER — no decode. `UIImage(contentsOfFile:)` would decode
/// the whole bitmap, which is far too expensive for a sizing pass that runs per row per layout.
func chatMediaImageHeaderSize(atPath path: String) -> CGSize? {
  guard
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
    let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
    let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
    width > 1.0, height > 1.0
  else { return nil }
  // EXIF orientations 5–8 are the rotated ones: the stored pixel dimensions are transposed
  // relative to how the image displays, and the bubble is sized from the DISPLAYED aspect.
  let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
  let transposed = orientation >= 5 && orientation <= 8
  return transposed
    ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
}

private func cachedNaturalMediaSize(for mediaUrl: String?) -> CGSize? {
  guard let mediaUrl, !mediaUrl.isEmpty else { return nil }
  guard let value = chatMediaNaturalSizeCache.object(forKey: mediaUrl as NSString) else {
    return nil
  }
  let size = value.cgSizeValue
  guard size.width > 1.0, size.height > 1.0 else { return nil }
  return size
}

private func cacheNaturalMediaSize(_ size: CGSize, for mediaUrl: String?) {
  guard let mediaUrl, !mediaUrl.isEmpty else { return }
  guard size.width > 1.0, size.height > 1.0 else { return }
  chatMediaNaturalSizeCache.setObject(NSValue(cgSize: size), forKey: mediaUrl as NSString)
  chatMediaThumbDerivedSizeKeys.removeObject(forKey: mediaUrl as NSString)
  // Every existing caller of this function now also teaches the durable store, so a photo the
  // user has seen ONCE is sized exactly on every later launch.
  if let identity = chatMediaNaturalSizeIdentity(mediaUrl) {
    ChatMediaNaturalSizeStore.shared.record(size, for: identity)
  }
}

private func resolvedLocalMediaPath(_ mediaUrl: String?) -> String? {
  guard let mediaUrl, !mediaUrl.isEmpty else { return nil }
  let trimmed = mediaUrl.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }

  let encodedTrimmed =
    trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
  if let url = URL(string: trimmed) ?? URL(string: encodedTrimmed), url.isFileURL {
    return url.path
  }
  if trimmed.hasPrefix("/") {
    return trimmed
  }
  if let decoded = trimmed.removingPercentEncoding, decoded.hasPrefix("/") {
    return decoded
  }
  if trimmed.hasPrefix("file://") {
    let path = String(trimmed.dropFirst(7))
    return path.removingPercentEncoding ?? path
  }
  return nil
}

private func cachedVideoHasAudio(for mediaUrl: String?) -> Bool? {
  guard let mediaUrl, !mediaUrl.isEmpty else { return nil }
  return chatMediaAudioAvailabilityCache.object(forKey: mediaUrl as NSString)?.boolValue
}

private func cacheVideoHasAudio(_ hasAudio: Bool, for mediaUrl: String?) {
  guard let mediaUrl, !mediaUrl.isEmpty else { return }
  chatMediaAudioAvailabilityCache.setObject(NSNumber(value: hasAudio), forKey: mediaUrl as NSString)
}

private func probeLocalMediaSize(for mediaUrl: String?) -> CGSize? {
  guard let resolvedPath = resolvedLocalMediaPath(mediaUrl) else { return nil }
  guard !resolvedPath.isEmpty else { return nil }
  // Header first — a full decode here would run on the sizing path.
  if let headerSize = chatMediaImageHeaderSize(atPath: resolvedPath) {
    return headerSize
  }
  if let image = UIImage(contentsOfFile: resolvedPath),
    image.size.width > 1.0, image.size.height > 1.0
  {
    return image.size
  }
  // Fall back: probe as video via AVAsset.
  let fileURL = URL(fileURLWithPath: resolvedPath)
  let asset = AVURLAsset(url: fileURL)
  guard let track = asset.tracks(withMediaType: .video).first else { return nil }
  let transformed = track.naturalSize.applying(track.preferredTransform)
  let w = abs(transformed.width)
  let h = abs(transformed.height)
  guard w > 1, h > 1 else { return nil }
  return CGSize(width: w, height: h)
}

private let chatVideoAudioProbeLock = NSLock()
private var chatVideoAudioProbesInFlight = Set<String>()

/// Answers from the memo only; a miss starts one async track load per url and calls
/// `completion` on main once the memo is filled.
private func probeLocalVideoHasAudio(
  for mediaUrl: String?, completion: (() -> Void)? = nil
) -> Bool? {
  if let cached = cachedVideoHasAudio(for: mediaUrl) {
    return cached
  }
  guard let mediaUrl, let resolvedPath = resolvedLocalMediaPath(mediaUrl) else { return nil }
  chatVideoAudioProbeLock.lock()
  let started = chatVideoAudioProbesInFlight.insert(mediaUrl).inserted
  chatVideoAudioProbeLock.unlock()
  guard started else { return nil }
  let asset = AVURLAsset(url: URL(fileURLWithPath: resolvedPath))
  Task.detached(priority: .utility) {
    let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
    let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
    chatVideoAudioProbeLock.lock()
    chatVideoAudioProbesInFlight.remove(mediaUrl)
    chatVideoAudioProbeLock.unlock()
    guard !videoTracks.isEmpty else { return }
    await MainActor.run {
      cacheVideoHasAudio(!audioTracks.isEmpty, for: mediaUrl)
      completion?()
    }
  }
  return nil
}

private func resolvedMediaNaturalSize(for row: ChatListRow) -> CGSize? {
  if let mw = row.mediaWidth, let mh = row.mediaHeight, mw > 1.0, mh > 1.0 {
    return CGSize(width: mw, height: mh)
  }
  if let cached = cachedNaturalMediaSize(for: row.mediaUrl) {
    return cached
  }
  // The local file this row renders from, if the memo knows that address instead. One
  // photo has several urls (remote, signed, vault path, container file) and the sizing
  // path must recognise the size whichever one it was learned under.
  if let local = row.localMediaUrl, !local.isEmpty,
    let cachedLocal = cachedNaturalMediaSize(for: local)
  {
    return cachedLocal
  }
  if let local = row.localMediaUrl, !local.isEmpty,
    let identity = chatMediaNaturalSizeIdentity(local),
    let stored = ChatMediaNaturalSizeStore.shared.size(for: identity)
  {
    cacheNaturalMediaSize(stored, for: row.mediaUrl)
    return stored
  }
  // Remembered from a previous launch. Without this, a photo whose payload carries no
  // dimensions was sized as a square on EVERY cold launch, because the two sources above are
  // in-memory only and the one below only answers for local files.
  if let identity = chatMediaNaturalSizeIdentity(row.mediaUrl),
    let stored = ChatMediaNaturalSizeStore.shared.size(for: identity)
  {
    chatMediaNaturalSizeCache.setObject(
      NSValue(cgSize: stored), forKey: (row.mediaUrl ?? "") as NSString)
    chatMediaThumbDerivedSizeKeys.removeObject(forKey: (row.mediaUrl ?? "") as NSString)
    return stored
  }
  if let local = probeLocalMediaSize(for: row.mediaUrl) {
    cacheNaturalMediaSize(local, for: row.mediaUrl)
    return local
  }
  // Already downloaded: the bytes are in the vault under the media's stable identity. Reading
  // the header (no decode) sizes the row exactly NOW, instead of guessing a square and letting
  // the cell's decode correct it a beat later — which is the visible shift.
  if let raw = row.mediaUrl,
    let fileURL = VibeMediaVault.shared.cachedURL(
      for: chatMediaCacheKey(raw, mediaKey: row.mediaKey), kind: .image),
    let headerSize = chatMediaImageHeaderSize(atPath: fileURL.path)
  {
    cacheNaturalMediaSize(headerSize, for: raw)
    return headerSize
  }
  // Nothing on disk yet — but the message carries a blur thumb with the same shape. Its own
  // pixel size is useless as a natural size (a 32×20 thumb would size a 120pt bubble), so scale
  // it to a canonically large width: the square fallback this replaces already assumed a
  // full-width photo, and this keeps that assumption while fixing the SHAPE.
  if let aspect = chatMediaThumbnailAspect(row.thumbnailBase64 ?? row.attachmentThumbnailsB64.first),
    let raw = row.mediaUrl, !raw.isEmpty
  {
    let canonicalWidth: CGFloat = 1024.0
    let derived = CGSize(width: canonicalWidth, height: max(1.0, canonicalWidth * aspect))
    // In-memory ONLY. This is the thumb's shape, not the media's true pixel size, and must
    // never reach the durable store — the real size overwrites it once the full image decodes.
    chatMediaNaturalSizeCache.setObject(NSValue(cgSize: derived), forKey: raw as NSString)
    chatMediaThumbDerivedSizeKeys.setObject(NSNumber(value: true), forKey: raw as NSString)
    return derived
  }
  return nil
}

/// True while the memo's size for this url is the blur thumb's shape (route 5), so a height
/// built on it stays provisional and is never persisted as exact.
func chatMediaNaturalSizeIsThumbDerived(for mediaUrl: String?) -> Bool {
  guard let mediaUrl, !mediaUrl.isEmpty else { return false }
  return chatMediaThumbDerivedSizeKeys.object(forKey: mediaUrl as NSString) != nil
}

/// Is the media's real aspect ratio known RIGHT NOW, without touching the disk? Payload
/// dimensions and the in-memory memo only — deliberately not the durable store, the vault
/// header or a local probe, all of which hit the filesystem. This runs per row on the height
/// path, and its one job is to answer "did the thing that made this height a guess go away?".
/// The decode that resolves an image fills the memo, so this flips true exactly then.
func chatMediaNaturalAspectIsKnownInMemory(for row: ChatListRow) -> Bool {
  if let mw = row.mediaWidth, let mh = row.mediaHeight, mw > 1.0, mh > 1.0 { return true }
  // A memo entry that is only the thumb's shape is still a guess.
  if cachedNaturalMediaSize(for: row.mediaUrl) != nil,
    !chatMediaNaturalSizeIsThumbDerived(for: row.mediaUrl)
  {
    return true
  }
  // The local url the cell rendered from, when it differs from the row's. Same reason
  // `reportNaturalMediaSizeIfNeeded` records under both — the two addresses for one photo
  // are the whole bug, and a memo that answers for one of them must answer for the row.
  if let local = row.localMediaUrl, !local.isEmpty,
    cachedNaturalMediaSize(for: local) != nil
  {
    return true
  }
  // The durable store is loaded at launch, so sizing and staleness agree on a cold open.
  if let identity = chatMediaNaturalSizeIdentity(row.mediaUrl),
    ChatMediaNaturalSizeStore.shared.contains(identity)
  {
    return true
  }
  return false
}

/// Which source answered `resolvedMediaNaturalSize` — the single decision behind a media row's
/// height, and therefore behind every media height shift. Diagnostics only (`[HeightShift]`).
func chatMediaNaturalSizeSourceLabel(for row: ChatListRow) -> String {
  guard row.kind == .message else { return "-" }
  switch row.visualKind {
  case .media, .video, .sticker: break
  default: return "-"
  }
  if chatMediaGridImageCount(row) > 1 { return "grid" }
  if let mw = row.mediaWidth, let mh = row.mediaHeight, mw > 1.0, mh > 1.0 { return "payload" }
  if cachedNaturalMediaSize(for: row.mediaUrl) != nil { return "memo" }
  if let identity = chatMediaNaturalSizeIdentity(row.mediaUrl),
    ChatMediaNaturalSizeStore.shared.contains(identity)
  {
    return "store"
  }
  if probeLocalMediaSize(for: row.mediaUrl) != nil { return "local" }
  if let raw = row.mediaUrl,
    VibeMediaVault.shared.cachedURL(
      for: chatMediaCacheKey(raw, mediaKey: row.mediaKey), kind: .image) != nil
  {
    return "vault"
  }
  if chatMediaThumbnailAspect(row.thumbnailBase64 ?? row.attachmentThumbnailsB64.first) != nil {
    return "thumb"
  }
  return "NONE-square"
}

private func resolvedStickerAnimationFilePath(for row: ChatListRow) -> String? {
  guard row.kind == .message, row.visualKind == .sticker else { return nil }

  let store = ChatStickerPackStore.shared
  if let stickerId = row.stickerId,
    let sticker = store.sticker(byId: stickerId),
    let path = store.lottieFilePath(for: sticker)
  {
    return path
  }

  if let bundleFileName = row.stickerBundleFileName {
    if let packId = row.stickerPackId, !packId.isEmpty {
      let sticker = StickerPackSticker(
        id: row.stickerId ?? bundleFileName,
        packId: packId,
        bundleFileName: bundleFileName,
        remoteUrl: row.mediaUrl,
        emoji: nil,
        width: Int(row.mediaWidth ?? 512.0),
        height: Int(row.mediaHeight ?? 512.0)
      )
      if let path = store.lottieFilePath(for: sticker) {
        return path
      }
    }

    for pack in store.installedPacks {
      if let sticker = pack.stickers.first(where: { $0.bundleFileName == bundleFileName }),
        let path = store.lottieFilePath(for: sticker)
      {
        return path
      }
    }

    let bundle = ChatStickerPackStore.resourceBundle() ?? Bundle.main
    if let path = bundle.path(forResource: bundleFileName, ofType: "json") {
      return path
    }
  }

  return nil
}

private func isTransparentStickerMessage(_ row: ChatListRow) -> Bool {
  row.kind == .message && row.visualKind == .sticker
}

private func usesFullBleedMediaLayout(_ row: ChatListRow) -> Bool {
  guard row.kind == .message else { return false }
  if isTransparentStickerMessage(row) {
    return false
  }
  if hasMediaCaptionLayout(row) {
    return false
  }
  return (row.visualKind == .media && row.messageType != "file") || row.visualKind == .video
    || row.visualKind == .videoNote
}

/// Media-with-caption bubbles (image/video + description) draw the media nearly
/// edge-to-edge — a hairline inset instead of the full text-bubble padding — with the
/// caption block hugging the bubble bottom. Files keep the padded document layout and
/// video notes stay circular.
let mediaCaptionEdgeInset: CGFloat = 1.5
let mediaCaptionTopGap: CGFloat = 6.0
let mediaCaptionBottomPadding: CGFloat = 4.0

func usesEdgeMediaCaptionLayout(_ row: ChatListRow) -> Bool {
  guard hasMediaCaptionLayout(row), !isTransparentStickerMessage(row) else { return false }
  return (row.visualKind == .media && row.messageType != "file") || row.visualKind == .video
}

/// Bridge multi-image sends carry every picked image as a sealed blob on ONE message —
/// two or more render as an inline tile grid instead of the single hero image.
let chatMediaGridMaxTiles = 6
let chatMediaGridGap: CGFloat = 2.0

func chatMediaGridImageCount(_ row: ChatListRow) -> Int {
  guard row.kind == .message, row.visualKind == .media, row.messageType != "file" else {
    return 0
  }
  let count = max(
    row.agentBridgeAttachmentsEnc.count,
    max(row.attachmentThumbnailsB64.count, row.attachmentUrls.count))
  // Multi-image only; a single picture uses the hero mediaImageView path.
  return count > 1 ? count : 0
}

/// True when the row's only media source is sealed bridge image blob(s) or durable
/// thumbs (no remote/local url) — common after agent-group send before/without CDN url.
func chatRowHasBridgeImageBlobsOnly(_ row: ChatListRow) -> Bool {
  let hasBlobs = !row.agentBridgeAttachmentsEnc.isEmpty || !row.attachmentThumbnailsB64.isEmpty
  guard hasBlobs else { return false }
  let media =
    (row.localMediaUrl ?? row.mediaUrl)?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  return media.isEmpty
}

private func chatMediaGridColumns(_ tiles: Int) -> Int {
  tiles <= 4 ? 2 : 3
}

/// A caption wants the bubble's width for text, so the images page in place;
/// without one the bubble *is* the picture and the deck can spend a few points of
/// height letting the stack read as a stack.
func chatMediaStackMode(_ row: ChatListRow) -> ChatMediaStackMode {
  hasMediaCaptionLayout(row) ? .carousel : .deck
}

/// The single height answer for a multi-image bubble, used by both the sizing
/// pass and the layout pass. Two of these that disagree is a visible row shift.
func chatMediaStackHeight(for row: ChatListRow, width: CGFloat) -> CGFloat {
  let count = chatMediaGridImageCount(row)
  guard count > 1 else { return 0 }
  return ChatMediaStackGeometry.height(
    count: count,
    width: width,
    mode: chatMediaStackMode(row),
    aspect: ChatMediaStackGeometry.cardAspect(natural: resolvedMediaNaturalSize(for: row))
  )
}

/// Row-major tile frames (origin 0,0). Tiles in a full row are square; a short final
/// row stretches its tiles to share the full width, so more images = smaller tiles and
/// the grid always fills the bubble.
func chatMediaGridLayout(count: Int, width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
  let tiles = min(max(count, 0), chatMediaGridMaxTiles)
  guard tiles > 1, width > 1.0 else { return ([], 0.0) }
  let cols = chatMediaGridColumns(tiles)
  let rowCount = Int(ceil(Double(tiles) / Double(cols)))
  let rowHeight = (width - CGFloat(cols - 1) * chatMediaGridGap) / CGFloat(cols)
  var frames: [CGRect] = []
  var index = 0
  for rowIdx in 0..<rowCount {
    let inRow = min(cols, tiles - index)
    let tileWidth = (width - CGFloat(inRow - 1) * chatMediaGridGap) / CGFloat(inRow)
    let y = CGFloat(rowIdx) * (rowHeight + chatMediaGridGap)
    for col in 0..<inRow {
      frames.append(
        CGRect(
          x: CGFloat(col) * (tileWidth + chatMediaGridGap),
          y: y,
          width: tileWidth,
          height: rowHeight
        ))
    }
    index += inRow
  }
  let height = CGFloat(rowCount) * rowHeight + CGFloat(rowCount - 1) * chatMediaGridGap
  return (frames, height)
}

private func usesTransparentAgentStreamingLayout(_ row: ChatListRow) -> Bool {
  // Streaming agent text now renders inside a normal bubble that grows smoothly
  // as chunks arrive (the old behaviour floated transparent text with no
  // background until the response finalized, which looked like the text was
  // outside the bubble and then snapped into it). Keep the helper so all call
  // sites compile, but always take the in-bubble path.
  _ = row
  return false
}

private func effectiveMetaTopSpacing(for row: ChatListRow) -> CGFloat {
  isTransparentStickerMessage(row) ? stickerMetaTopSpacing : bubbleMetaTopSpacing
}

private let bubbleLinkPreviewHeight: CGFloat = 78.0
private let bubbleLinkPreviewSpacing: CGFloat = 8.0
private let bubbleLinkPreviewMinWidth: CGFloat = 220.0
// Telegram-style rich music card (SoundCloud/YouTube links): fixed geometry so the
// bubble height is deterministic (estimate/exact drift is paid as a visible warmup
// correction — never size this card off async metadata).
//
// Reference (Telegram SoundCloud bubble):
//   [ ~10pt pad ]
//   [ nearly-square artwork, ~12pt corner, centered dark play ]
//   [ ~10pt ]
//   [ Source  (SoundCloud) ]
//   [ Title ]
//   [ Artist ]
//   [ time ✓ bottom-trailing ]
private let bubbleMusicLinkArtTop: CGFloat = 8.0
private let bubbleMusicLinkArtBottomGap: CGFloat = 8.0
private let bubbleMusicLinkTextBlockHeight: CGFloat = 58.0  // site + title + artist
private let bubbleMusicLinkBottomPad: CGFloat = 8.0
private let bubbleMusicLinkArtworkHeight: CGFloat = 236.0
private let bubbleMusicLinkPreviewHeight: CGFloat =
  bubbleMusicLinkArtTop + bubbleMusicLinkArtworkHeight + bubbleMusicLinkArtBottomGap
  + bubbleMusicLinkTextBlockHeight + bubbleMusicLinkBottomPad
private let bubbleMusicLinkPreviewMinWidth: CGFloat = 270.0
// Gap between rich-text blocks (prose ↔ code card ↔ runtime summary). A touch more
// air keeps multi-block agent answers from stacking into one dense column.
private let bubbleRichTextBlockSpacing: CGFloat = 10.0
private let bubbleURLDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
private let bubbleInternalChatIdRegex = try! NSRegularExpression(
  pattern: "[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}"
)

private struct BubbleRichTextMeasurement {
  let height: CGFloat
  let maxWidth: CGFloat
}

private struct BubbleLinkPreviewData {
  let url: URL
  let title: String
  let site: String
  let icon: UIImage?
}

// Compact, Claude-Code-style label for one enriched tool node:
//   "Read ChatEngine.swift", "Edit chat.ex  +12 −3", "Run git status", …
// Mirrors the agent view's `agentNodeDisplayLabel` so the in-bubble compact feed
// reads identically to the full agent view. Kept at file scope (not private to a
// cell) so history rendering can reuse the same parsing style.
// "2s", "1m 5s" — thinking duration in the CLI's compact style.
func chatAgentThinkingDurationText(_ ms: Int) -> String {
  let totalSeconds = max(1, ms / 1000)
  if totalSeconds < 60 { return "\(totalSeconds)s" }
  let minutes = totalSeconds / 60
  let seconds = totalSeconds % 60
  return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
}

// "639 tokens", "12.3k tokens" — reasoning token count, compact.
func chatAgentTokenCountText(_ tokens: Int) -> String {
  if tokens >= 1000 {
    let thousands = Double(tokens) / 1000.0
    return String(format: "%.1fk tokens", thousands)
  }
  return "\(tokens) tokens"
}

/// Wire MCP tool id stays `ask_fable`; user-facing copy is "ask advisor".
func chatAgentPrettyMcpLabel(_ text: String) -> String {
  guard !text.isEmpty else { return text }
  var out = text
  if let regex = try? NSRegularExpression(pattern: #"\bask\s+fable\b"#, options: .caseInsensitive) {
    let range = NSRange(out.startIndex..<out.endIndex, in: out)
    out = regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "ask advisor")
  }
  return out
}

func chatAgentNodeCompactLabel(_ node: ChatListRow.AgentProgressNode) -> String {
  guard let kind = node.kind, !kind.isEmpty else { return node.label }
  // Thinking rows read like the desktop CLI: "Thinking · N tokens" while the model is
  // still reasoning, "Thought for Ns · N tokens" once the step settles.
  if kind == "thinking" {
    let isRunning = ["running", "streaming"].contains(node.status.lowercased())
    var parts: [String] = []
    if !isRunning, let ms = node.durationMs, ms >= 1000 {
      parts.append("Thought for \(chatAgentThinkingDurationText(ms))")
    } else {
      parts.append("Thinking")
    }
    if let tokens = node.tokens, tokens > 0 {
      parts.append(chatAgentTokenCountText(tokens))
    }
    return parts.joined(separator: " · ")
  }
  if kind == "compacting" {
    let isRunning = ["running", "streaming", "in_progress", "active"].contains(node.status.lowercased())
    if isRunning { return "Compacting conversation…" }
    return node.label.isEmpty ? "Compacted conversation" : node.label
  }
  // MCP tools (Ask Advisor, ask_user, …): "MCP · ask advisor · 12s"
  // Wire id stays ask_fable; rewrite residual "ask fable" labels for display.
  if kind == "mcp" {
    var base = node.label
    if base.isEmpty {
      if let target = node.target, !target.isEmpty {
        base = "MCP · \(target)"
      } else {
        base = "MCP tool"
      }
    }
    base = chatAgentPrettyMcpLabel(base)
    let isRunning = ["running", "streaming", "in_progress", "active"].contains(node.status.lowercased())
    if !isRunning, let ms = node.durationMs, ms >= 500 {
      return "\(base) · \(chatAgentThinkingDurationText(ms))"
    }
    if isRunning { return "\(base)…" }
    return base
  }
  // "Read"/"Edit"/"Create"/"Run" are the CLI vocabulary: a file/command operation whose
  // `target` is the path or command, where the raw label ("Claude Read: /long/path") is worse
  // than the derived text. The native server agent uses the same coarse kinds for SEMANTIC
  // steps and ships a written label instead ("Checking your agents…", "No agent here") with no
  // target — deriving a verb there produced a bare, meaningless "Create"/"Fetch"/"Step".
  // Target present → CLI shape → verb + target. No target → trust the server's label.
  let hasTarget = (node.target?.isEmpty == false)
  if !hasTarget, !node.label.isEmpty, kind != "todo" {
    return node.label
  }
  let verb: String
  switch kind {
  case "read": verb = "Read"
  case "edit": verb = "Edit"
  case "write": verb = "Create"
  case "bash": verb = "Run"
  case "search": verb = "Search"
  case "web": verb = "Fetch"
  case "task": verb = "Step"
  case "todo":
    let a = node.action?.lowercased() ?? ""
    if a == "create" || a == "created" { return "Created Task" }
    if a == "update" || a == "updated" { return "Updated Task" }
    return "Create Task or Update Task"
  case "tool":
    // Fallback generic tools (non-MCP): keep label, append duration when settled.
    var base = node.label.isEmpty ? "Tool" : node.label
    if let target = node.target, !target.isEmpty, !base.localizedCaseInsensitiveContains(target) {
      base = "\(base) · \(target)"
    }
    if let ms = node.durationMs, ms >= 500,
      !["running", "streaming"].contains(node.status.lowercased())
    {
      return "\(base) · \(chatAgentThinkingDurationText(ms))"
    }
    return base
  default: return node.label
  }
  var text = verb
  if let target = node.target, !target.isEmpty {
    text += " \(target)"
  }
  var stats: [String] = []
  if let added = node.added, added > 0 { stats.append("+\(added)") }
  if let removed = node.removed, removed > 0 { stats.append("−\(removed)") }
  if !stats.isEmpty {
    text += "  " + stats.joined(separator: " ")
  }
  return text
}

// Compact multi-line feed for the live "loadings" (Read/Edit/Run rows building up
// as Claude/Codex works), rendered inside the streaming chat bubble via the normal
// text path. Each line is a status glyph + compact node label. Returns "" when
// there is no enriched flat tool feed (the built-in Vibe AI nested tree keeps its
// own minimalist behavior elsewhere).
func chatAgentProgressFeedText(
  _ nodes: [ChatListRow.AgentProgressNode],
  maxVisible: Int = 6
) -> String {
  // Only the flat, enriched tool feed (Claude/Codex bridge) — every node depth 0
  // and at least one carrying a `kind`.
  let flat = nodes.filter { $0.depth == 0 }
  guard !flat.isEmpty, flat.contains(where: { ($0.kind?.isEmpty == false) }) else {
    return ""
  }
  return flat.suffix(maxVisible).map { node in
    let glyph: String
    switch node.status.lowercased() {
    case "done", "complete", "completed", "success", "ok": glyph = "✓"
    case "error", "failed", "failure": glyph = "✕"
    default: glyph = "▸"  // running — not a markdown bullet glyph
    }
    return "\(glyph) \(chatAgentNodeCompactLabel(node))"
  }.joined(separator: "\n")
}


private func bubbleBaseText(for row: ChatListRow) -> (text: String, addPrefix: Bool) {
  if row.isAgentMessage {
    // No ✦ spark prefix on agent bubbles — the agent surface doesn't want it.
    // The default chat bubble is a COMPACT summary only. The live tool feed
    // (Read/Edit/Run loadings) and full progress live in the pushed full-page
    // agent view (reached via the per-bubble "view agent" affordance), NOT
    // inflated inline here. `chatAgentNodeCompactLabel`/`chatAgentProgressFeedText`
    // are kept at file scope so that surface (and history rendering) can reuse them.
    let body = row.plainContent ?? row.text
    return (body, false)
  }
  if row.isAgentMention {
    return (row.textWithoutMention, true)
  }
  return (row.text, false)
}

private func bubbleDisplayText(for row: ChatListRow) -> String {
  let payload = bubbleBaseText(for: row)
  guard payload.addPrefix else { return payload.text }
  let prefix = isRTL(payload.text) ? "\u{200F}✦ " : "✦ "
  return payload.text.isEmpty ? prefix : prefix + payload.text
}

private func bubbleParsedBlocks(for row: ChatListRow) -> [AgentParsedBlock] {
  let payload = bubbleBaseText(for: row)
  var blocks = ChatNativeAgentTextRenderer.parseBlocks(payload.text).filter { block in
    // Same no-diff rule as appendRuntimeIfNeeded below, applied to runtime cards the
    // text parser itself produced.
    if case .agentRuntime(let runtime) = block { return agentRuntimeHasDiff(runtime) }
    return true
  }
  func appendRuntimeIfNeeded() {
    // Never surface the finished runtime/diff card while the turn is still
    // streaming — the card is the END-of-turn summary; showing it mid-stream is
    // the "card renders before streaming is done" bug. It reappears once the row
    // is no longer live.
    guard !row.isStreamingText else { return }
    guard let runtime = row.agentRuntime else {
      // No log here: runtime=nil is the NORMAL case for every plain-prose agent
      // turn, so this fired once per agent row per configure (2–5× per cell as the
      // list reconfigures) — a synchronous NSLog on the scroll hot path that said
      // nothing actionable. The "appended card block" line below is the rare,
      // informative one and stays.
      return
    }
    // A turn that changed nothing has nothing to review — an empty "0 files changed
    // +0 -0 · Review" card is pure noise (typical for greeting/Q&A turns, especially
    // in group fan-out where every agent answers).
    guard agentRuntimeHasDiff(runtime) else { return }
    if blocks.contains(where: { block in
      if case .agentRuntime = block { return true }
      return false
    }) {
      return
    }
    NSLog("[AgentView] chatCell blocks: msg=\(row.messageId ?? row.key) appended card block files=\(runtime.diff?.files.count ?? -1) +\(runtime.diff?.additions ?? -1)/-\(runtime.diff?.deletions ?? -1) patchLen=\(runtime.diff?.patch?.count ?? -1)")
    blocks.append(.agentRuntime(runtime))
  }

  guard payload.addPrefix else {
    appendRuntimeIfNeeded()
    return blocks
  }

  let prefix = isRTL(payload.text) ? "\u{200F}✦ " : "✦ "
  if blocks.isEmpty {
    blocks = [.text(prefix)]
    appendRuntimeIfNeeded()
    return blocks
  }

  switch blocks[0] {
  case .text(let content):
    blocks[0] = .text(content.isEmpty ? prefix : prefix + content)
  case .code:
    blocks.insert(.text(prefix.trimmingCharacters(in: .whitespacesAndNewlines)), at: 0)
  case .agentPack:
    blocks.insert(.text(prefix.trimmingCharacters(in: .whitespacesAndNewlines)), at: 0)
  case .agentRuntime:
    blocks.insert(.text(prefix.trimmingCharacters(in: .whitespacesAndNewlines)), at: 0)
  }
  appendRuntimeIfNeeded()
  return blocks
}

private func bubbleUsesBlockLayout(_ row: ChatListRow) -> Bool {
  if bubbleUsesAgentTurnContent(row) {
    return false
  }
  guard row.kind == .message, row.visualKind == .text, row.messageType != "typing",
    row.messageType != "agent_progress_tree", row.isAgentMessage
  else {
    return false
  }
  let blocks = bubbleParsedBlocks(for: row)
  return blocks.contains { block in
    if case .code = block {
      return true
    }
    if case .agentPack = block {
      return true
    }
    if case .agentRuntime = block {
      return true
    }
    return false
  } || blocks.count > 1
}

private func bubbleRichTextStorageKey(for row: ChatListRow, blockIndex: Int) -> String {
  "\(row.key)#\(blockIndex)"
}

private func bubbleInternalChatId(from url: URL) -> String? {
  let host = url.host?.lowercased() ?? ""
  guard host.contains("vibe") || host.contains("vibegram") || url.scheme == "vibe" else {
    return nil
  }

  let path = url.path
  let nsPath = path as NSString
  let pathRange = NSRange(location: 0, length: nsPath.length)
  if let match = bubbleInternalChatIdRegex.firstMatch(in: path, range: pathRange) {
    return nsPath.substring(with: match.range)
  }

  if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
    let items = components.queryItems
  {
    for item in items {
      let lowercasedName = item.name.lowercased()
      if (lowercasedName.contains("chat") || lowercasedName.contains("id")),
        let value = item.value,
        !value.isEmpty
      {
        return value
      }
    }
  }

  return nil
}

private func bubbleCanPreviewURL(_ url: URL) -> Bool {
  guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
    return false
  }
  return bubbleInternalChatId(from: url) == nil
}

func bubblePreviewCandidateURL(for row: ChatListRow) -> URL? {
  guard row.kind == .message, row.visualKind == .text, row.messageType != "typing",
    !hasInlineAttachment(row), !row.isAgentMessage, !row.isAgentMention
  else {
    return nil
  }

  let sourceText = bubbleBaseText(for: row).text
  guard !sourceText.isEmpty else { return nil }
  if bubbleParsedBlocks(for: row).contains(where: {
    if case .agentPack = $0 { return true }
    if case .agentRuntime = $0 { return true }
    return false
  }) {
    return nil
  }

  let range = NSRange(sourceText.startIndex..., in: sourceText)
  let matches = bubbleURLDetector.matches(in: sourceText, options: [], range: range)
  for match in matches {
    guard let url = match.url, bubbleCanPreviewURL(url) else { continue }
    return url
  }
  return nil
}

private func bubblePreviewURL(for row: ChatListRow) -> URL? {
  guard let url = bubblePreviewCandidateURL(for: row), bubbleIsMusicPreviewURL(url) else {
    return nil
  }
  return url
}

/// Music page hosts get the tall Telegram-style artwork card instead of the
/// compact strip. Mirrors the server's `YtDlp.music_page_url?` host list.
/// Shared with the composer draft-preview banner (`ChatInputBar`).
func bubbleIsMusicPreviewURL(_ url: URL) -> Bool {
  guard let host = url.host?.lowercased() else { return false }
  let musicHosts = [
    "soundcloud.com", "on.soundcloud.com", "snd.sc",
    "youtube.com", "youtu.be", "music.youtube.com",
  ]
  return musicHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
}

private func bubbleRowPreviewHeight(for row: ChatListRow) -> CGFloat {
  guard let url = bubblePreviewURL(for: row) else { return 0.0 }
  return bubbleIsMusicPreviewURL(url) ? bubbleMusicLinkPreviewHeight : bubbleLinkPreviewHeight
}

private func bubbleRowPreviewMinWidth(for row: ChatListRow) -> CGFloat {
  guard let url = bubblePreviewURL(for: row) else { return 0.0 }
  // Music cards want the full bubble width (clamped by the caller's max).
  return bubbleIsMusicPreviewURL(url) ? bubbleMusicLinkPreviewMinWidth : bubbleLinkPreviewMinWidth
}

func bubbleMusicPreviewFallbackSite(for url: URL) -> String {
  guard let host = url.host?.lowercased() else { return bubblePreviewSiteLabel(for: url) }
  if host.contains("soundcloud") || host == "snd.sc" { return "SoundCloud" }
  if host.contains("youtu") { return "YouTube" }
  return bubblePreviewSiteLabel(for: url)
}

func bubblePreviewSiteLabel(for url: URL) -> String {
  guard let host = url.host?.lowercased(), !host.isEmpty else {
    return url.absoluteString
  }
  return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

private func bubblePreviewTitleFallback(for url: URL) -> String {
  let site = bubblePreviewSiteLabel(for: url)
  let trimmedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  guard !trimmedPath.isEmpty else { return site }
  let compactPath = trimmedPath.count > 32 ? String(trimmedPath.prefix(32)) + "..." : trimmedPath
  return site + "/" + compactPath
}

private func measureBubbleCodeBlockHeight(
  code: String,
  language: String?,
  baseFont: UIFont,
  availableWidth: CGFloat,
  storageKey: String
) -> CGFloat {
  let codeFont = UIFont.monospacedSystemFont(
    ofSize: max(12.5, baseFont.pointSize - 2.5),
    weight: .regular
  )
  let hPad: CGFloat = 12.0
  let vPad: CGFloat = 10.0
  let barHeight: CGFloat = 32.0
  let labelWidth = max(1.0, availableWidth - (hPad * 2.0))
  let totalLineCount = code.components(separatedBy: "\n").count
  let isExpanded = AgentCodeBlockView.isExpanded(
    code: code,
    language: language,
    storageKey: storageKey
  )
  let visibleCode: String
  if !isExpanded && totalLineCount > 12 {
    visibleCode = code.components(separatedBy: "\n").prefix(12).joined(separator: "\n")
  } else {
    visibleCode = code
  }

  let attributed = NSAttributedString(
    string: visibleCode,
    attributes: [
      .font: codeFont,
      .foregroundColor: UIColor.white.withAlphaComponent(0.88),
    ]
  )
  let textHeight = ceil(
    attributed.boundingRect(
      with: CGSize(width: labelWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    ).height
  )
  let bodyHeight = max(ceil(codeFont.lineHeight), textHeight)
  return barHeight + vPad + bodyHeight + vPad + 8.0
}

private func measureBubbleRichText(for row: ChatListRow, availableWidth: CGFloat) -> BubbleRichTextMeasurement {
  let blocks = bubbleParsedBlocks(for: row)
  guard !blocks.isEmpty else {
    return BubbleRichTextMeasurement(height: 0.0, maxWidth: 0.0)
  }

  let font = bubbleMessageFont
  let textColor = row.isMe ? UIColor.white : UIColor.label
  var totalHeight: CGFloat = 0.0
  var maxWidth: CGFloat = 0.0

  for (index, block) in blocks.enumerated() {
    switch block {
    case .text(let content):
      let attributed = ChatNativeAgentTextRenderer.makeAttributedText(
        text: content,
        font: font,
        textColor: textColor
      )
      let measured = ChatNativeAgentTextRenderer.measuredSize(for: attributed, width: availableWidth)
      totalHeight += max(ceil(font.lineHeight), measured.height)
      maxWidth = max(maxWidth, min(availableWidth, measured.width))
    case .code(let content, let language):
      totalHeight += measureBubbleCodeBlockHeight(
        code: content,
        language: language,
        baseFont: font,
        availableWidth: availableWidth,
        storageKey: bubbleRichTextStorageKey(for: row, blockIndex: index)
      )
      maxWidth = max(maxWidth, availableWidth)
    case .agentPack(let pack):
      totalHeight += AgentIntegrationPackView.measuredHeight(
        pack: pack,
        availableWidth: availableWidth,
        storageKey: bubbleRichTextStorageKey(for: row, blockIndex: index)
      )
      maxWidth = max(maxWidth, availableWidth)
    case .agentRuntime(let runtime):
      totalHeight += AgentRuntimeSummaryView.measuredHeight(
        runtime: runtime,
        availableWidth: availableWidth,
        isExpanded: false
      )
      maxWidth = max(maxWidth, availableWidth)
    }

    if index < blocks.count - 1 {
      totalHeight += bubbleRichTextBlockSpacing
    }
  }

  return BubbleRichTextMeasurement(height: totalHeight, maxWidth: maxWidth)
}

private func parseBubbleMarkdown(
  text: String,
  font: UIFont,
  textColor: UIColor? = nil,
  useSharedAgentRenderer: Bool = false
)
  -> NSAttributedString
{
  _ = useSharedAgentRenderer
  let rendered = ChatNativeAgentTextRenderer.makeAttributedText(
    text: text,
    font: font,
    textColor: textColor ?? .label
  )
  guard isRTL(text) else { return rendered }
  // The shared renderer right-aligns RTL, which outranks the label alignment. Bubbles
  // want the block at the plate left inset, with RTL shaping kept by the base direction.
  let aligned = NSMutableAttributedString(attributedString: rendered)
  aligned.enumerateAttribute(
    .paragraphStyle, in: NSRange(location: 0, length: aligned.length)
  ) { value, range, _ in
    guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
    else { return }
    style.alignment = .left
    aligned.addAttribute(.paragraphStyle, value: style, range: range)
  }
  return aligned
}

private func bubbleDisplayAttributedString(
  for row: ChatListRow, font: UIFont, textColor: UIColor? = nil
) -> NSAttributedString {
  return parseBubbleMarkdown(
    text: bubbleDisplayText(for: row),
    font: font,
    textColor: textColor,
    useSharedAgentRenderer: row.isAgentMessage || row.isAgentMention
  )
}

private typealias AgentStreamingLabel = ChatNativeStreamingTextLabel

private final class BubbleRichTextView: UIView {
  private var blockViews: [UIView] = []
  private var blockFrames: [CGRect] = []
  private var lastSignature = ""

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func reset() {
    blockViews.forEach { $0.removeFromSuperview() }
    blockViews = []
    blockFrames = []
    lastSignature = ""
  }

  @discardableResult
  func configure(row: ChatListRow, textColor: UIColor, availableWidth: CGFloat) -> CGFloat {
    let blocks = bubbleParsedBlocks(for: row)
    guard !blocks.isEmpty else {
      reset()
      return 0.0
    }

    let signature = blocks.enumerated().map { index, block in
      switch block {
      case .text:
        return "T\(index)"
      case .code:
        return "C\(index)"
      case .agentPack:
        return "P\(index)"
      case .agentRuntime:
        return "R\(index)"
      }
    }.joined(separator: "-")

    if signature != lastSignature || blockViews.count != blocks.count {
      reset()
      blockViews = blocks.map { block in
        switch block {
        case .text:
          let label = ChatNativeStreamingTextLabel()
          label.numberOfLines = 0
          label.backgroundColor = .clear
          addSubview(label)
          return label
        case .code:
          let card = AgentCodeBlockView()
          addSubview(card)
          return card
        case .agentPack:
          let packView = AgentIntegrationPackView()
          addSubview(packView)
          return packView
        case .agentRuntime:
          let runtimeView = AgentRuntimeSummaryView()
          addSubview(runtimeView)
          return runtimeView
        }
      }
      lastSignature = signature
    }

    let baseFont = bubbleMessageFont
    var yOffset: CGFloat = 0.0
    blockFrames = []

    var lastTextIndex: Int?
    for (index, block) in blocks.enumerated() {
      if case .text = block {
        lastTextIndex = index
      }
    }

    for (index, block) in blocks.enumerated() {
      let view = blockViews[index]
      switch block {
      case .text(let content):
        let label = view as! ChatNativeStreamingTextLabel
        let attributed = ChatNativeAgentTextRenderer.makeAttributedText(
          text: content,
          font: baseFont,
          textColor: textColor
        )
        let measured = ChatNativeAgentTextRenderer.measuredSize(for: attributed, width: availableWidth)
        let height = max(ceil(baseFont.lineHeight), measured.height)
        label.applyStreamingText(
          attributed,
          rawText: content,
          isStreaming: row.isStreamingText && index == lastTextIndex
        )
        blockFrames.append(CGRect(x: 0.0, y: yOffset, width: availableWidth, height: height))
        yOffset += height
      case .code(let content, let language):
        let card = view as! AgentCodeBlockView
        let cardHeight = card.configure(
          code: content,
          language: language,
          textColor: textColor,
          baseFont: baseFont,
          availableWidth: availableWidth,
          storageKey: bubbleRichTextStorageKey(for: row, blockIndex: index)
        )
        blockFrames.append(CGRect(x: 0.0, y: yOffset, width: availableWidth, height: cardHeight))
        yOffset += cardHeight
      case .agentPack(let pack):
        let packView = view as! AgentIntegrationPackView
        let packHeight = packView.configure(
          pack: pack,
          textColor: textColor,
          availableWidth: availableWidth,
          storageKey: bubbleRichTextStorageKey(for: row, blockIndex: index)
        )
        blockFrames.append(CGRect(x: 0.0, y: yOffset, width: availableWidth, height: packHeight))
        yOffset += packHeight
      case .agentRuntime(let runtime):
        let runtimeView = view as! AgentRuntimeSummaryView
        let runtimeHeight = runtimeView.configure(
          runtime: runtime,
          textColor: textColor,
          availableWidth: availableWidth,
          isExpanded: false
        )
        blockFrames.append(CGRect(x: 0.0, y: yOffset, width: availableWidth, height: runtimeHeight))
        yOffset += runtimeHeight
      }

      if index < blocks.count - 1 {
        yOffset += bubbleRichTextBlockSpacing
      }
    }

    setNeedsLayout()
    return yOffset
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    for (index, blockView) in blockViews.enumerated() where index < blockFrames.count {
      blockView.frame = blockFrames[index]
    }
  }
}

private final class BubbleLinkPreviewStore {
  static let shared = BubbleLinkPreviewStore()

  private var cached: [String: BubbleLinkPreviewData] = [:]
  private var inFlight: [String: [(BubbleLinkPreviewData?) -> Void]] = [:]
  private var activeProviders: [String: LPMetadataProvider] = [:]
  private let availabilityLock = NSLock()
  private var unavailable: Set<String> = []

  private init() {}

  /// Disk keys for one preview URL. The image rides the shared chat-media disk cache
  /// (same eviction//clear plumbing as every other cached image); the text fields ride
  /// UserDefaults because they are two short strings.
  private static func imageDiskKey(_ url: String) -> String { "linkpreview.v2|\(url)" }
  private static func textDefaultsKey(_ url: String) -> String { "linkpreview.meta.v2|\(url)" }

  func isUnavailable(url: URL) -> Bool {
    availabilityLock.lock()
    defer { availabilityLock.unlock() }
    return unavailable.contains(url.absoluteString)
  }

  func fetch(url: URL, completion: @escaping (BubbleLinkPreviewData?) -> Void) {
    let key = url.absoluteString
    if let cachedData = cached[key] {
      DispatchQueue.main.async {
        completion(cachedData)
      }
      return
    }
    if isUnavailable(url: url) {
      DispatchQueue.main.async {
        completion(nil)
      }
      return
    }

    inFlight[key, default: []].append(completion)
    guard inFlight[key]?.count == 1 else { return }

    // Disk before network. `cached` is per-process, so without this every relaunch
    // re-ran the full LPMetadataProvider scrape AND re-downloaded the og:image for
    // every link bubble on screen — the reported "any link with an image isn't cached,
    // it refetches the image each time we reopen". A preview is immutable enough to
    // serve from disk indefinitely; a miss still falls through to the live fetch below.
    let imageKey = Self.imageDiskKey(key)
    chatMediaDiskCacheQueue.async { [weak self] in
      guard let self else { return }
      let meta = UserDefaults.standard.stringArray(forKey: Self.textDefaultsKey(key))
      guard let meta, meta.count == 2,
        !meta[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        DispatchQueue.main.async { self.startRemoteFetch(url: url, key: key) }
        return
      }
      var image: UIImage?
      if let cachedImage = chatMediaImageCache.object(forKey: imageKey as NSString) {
        image = cachedImage
      } else if let data = chatMediaDiskCacheLoad(imageKey), let decoded = UIImage(data: data) {
        chatMediaImageCacheStore(decoded, forKey: imageKey)
        image = decoded
      }
      self.finish(
        key: key,
        data: BubbleLinkPreviewData(url: url, title: meta[0], site: meta[1], icon: image),
        persist: false
      )
    }
  }

  private func startRemoteFetch(url: URL, key: String) {
    let provider = LPMetadataProvider()
    activeProviders[key] = provider
    provider.startFetchingMetadata(for: url) { [weak self] metadata, _ in
      guard let self, let metadata else {
        self?.finishUnavailable(key: key)
        return
      }
      let resolvedURL = metadata.originalURL ?? metadata.url ?? url
      let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !title.isEmpty else {
        self.finishUnavailable(key: key)
        return
      }

      self.loadPreviewImage(from: metadata) { image in
        self.finish(
          key: key,
          data: BubbleLinkPreviewData(
            url: resolvedURL,
            title: title,
            site: bubblePreviewSiteLabel(for: resolvedURL),
            icon: image
          )
        )
      }
    }
  }

  private func loadPreviewImage(
    from metadata: LPLinkMetadata?,
    completion: @escaping (UIImage?) -> Void
  ) {
    let providers = [metadata?.iconProvider, metadata?.imageProvider].compactMap { $0 }
    guard let provider = providers.first(where: { $0.canLoadObject(ofClass: UIImage.self) }) else {
      DispatchQueue.main.async {
        completion(nil)
      }
      return
    }

    provider.loadObject(ofClass: UIImage.self) { object, _ in
      DispatchQueue.main.async {
        completion(object as? UIImage)
      }
    }
  }

  private func finishUnavailable(key: String) {
    DispatchQueue.main.async {
      self.availabilityLock.lock()
      self.unavailable.insert(key)
      self.availabilityLock.unlock()
      self.activeProviders.removeValue(forKey: key)
      let callbacks = self.inFlight.removeValue(forKey: key) ?? []
      callbacks.forEach { $0(nil) }
    }
  }

  private func finish(key: String, data: BubbleLinkPreviewData, persist: Bool = true) {
    DispatchQueue.main.async {
      self.availabilityLock.lock()
      self.unavailable.remove(key)
      self.availabilityLock.unlock()
      self.cached[key] = data
      self.activeProviders.removeValue(forKey: key)
      let callbacks = self.inFlight.removeValue(forKey: key) ?? []
      callbacks.forEach { $0(data) }
    }
    // Write-through so the NEXT launch reads disk instead of re-scraping. Only for
    // results that came off the network — a disk hit re-persisting itself is pure churn.
    guard persist else { return }
    let imageKey = Self.imageDiskKey(key)
    if let icon = data.icon {
      chatMediaImageCacheStore(icon, forKey: imageKey)
    }
    chatMediaDiskCacheQueue.async {
      UserDefaults.standard.set([data.title, data.site], forKey: Self.textDefaultsKey(key))
      // JPEG keeps og:image thumbnails small; they are photographic and never need alpha.
      if let icon = data.icon, let encoded = icon.jpegData(compressionQuality: 0.9) {
        chatMediaDiskCacheSave(encoded, forKey: imageKey)
      }
    }
  }
}

private struct BubbleMusicPreviewData {
  let url: URL
  let site: String
  let title: String
  let desc: String?
  let imageURLString: String?
}

/// Prefetch OpenGraph metadata + album art for a music page URL (composer draft
/// preview + send-morph). Warms the same caches the bubble card reads so the
/// outgoing cell paints cover immediately at fixed height (no mid-stream resize).
@discardableResult
func chatPrefetchMusicURLPreview(
  url: URL,
  completion: ((String, String, String?, String?) -> Void)? = nil
) -> Void {
  guard bubbleIsMusicPreviewURL(url) else {
    completion?(bubblePreviewSiteLabel(for: url), bubblePreviewTitleFallback(for: url), nil, nil)
    return
  }
  BubbleMusicPreviewStore.shared.fetch(url: url) { data in
    completion?(data.site, data.title, data.desc, data.imageURLString)
    if let imageURL = data.imageURLString, !imageURL.isEmpty {
      _ = chatLoadMusicCover(urlString: imageURL) { _ in }
    }
  }
}

/// OpenGraph metadata for the Telegram-style music card. `LPMetadataProvider`
/// drops `og:description`, so fetch the page head and parse the tags directly
/// (SoundCloud/YouTube serve them to plain GETs). Main-thread API, memoized per URL.
private final class BubbleMusicPreviewStore {
  static let shared = BubbleMusicPreviewStore()

  private var cached: [String: BubbleMusicPreviewData] = [:]
  private var inFlight: [String: [(BubbleMusicPreviewData) -> Void]] = [:]

  private init() {}

  func fetch(url: URL, completion: @escaping (BubbleMusicPreviewData) -> Void) {
    let key = url.absoluteString
    if let cachedData = cached[key] {
      DispatchQueue.main.async { completion(cachedData) }
      return
    }
    inFlight[key, default: []].append(completion)
    guard inFlight[key]?.count == 1 else { return }

    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
      forHTTPHeaderField: "User-Agent"
    )
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    VibeHTTP.shared.dataTask(with: request) { [weak self] data, response, _ in
      let resolvedURL = (response?.url) ?? url
      // og tags live in <head>; cap the parse window so huge pages stay cheap.
      let html = data.flatMap { String(data: $0.prefix(400_000), encoding: .utf8) } ?? ""
      let title = Self.ogContent("og:title", in: html)
        ?? Self.ogContent("twitter:title", in: html)
      let desc = Self.ogContent("og:description", in: html)
        ?? Self.ogContent("twitter:description", in: html)
      let rawImage = Self.ogContent("og:image", in: html)
        ?? Self.ogContent("twitter:image", in: html)
        ?? Self.ogContent("twitter:image:src", in: html)
      let image = Self.absolutizeURLString(rawImage, base: resolvedURL)
      let site = Self.ogContent("og:site_name", in: html)
      let result = BubbleMusicPreviewData(
        url: resolvedURL,
        site: site ?? bubbleMusicPreviewFallbackSite(for: resolvedURL),
        title: title ?? bubblePreviewTitleFallback(for: resolvedURL),
        desc: desc,
        imageURLString: image
      )
      DispatchQueue.main.async {
        guard let self else { return }
        self.cached[key] = result
        let callbacks = self.inFlight.removeValue(forKey: key) ?? []
        callbacks.forEach { $0(result) }
      }
    }.resume()
  }

  /// Turns protocol-relative (`//cdn…`) and root-relative (`/img…`) og:image values
  /// into absolute https URLs so cover loads don't silently fail.
  private static func absolutizeURLString(_ raw: String?, base: URL) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") { return trimmed }
    if trimmed.hasPrefix("//") { return "https:" + trimmed }
    if let absolute = URL(string: trimmed, relativeTo: base)?.absoluteString, !absolute.isEmpty {
      return absolute
    }
    return trimmed
  }

  /// `<meta property="og:x" content="...">` in either attribute order.
  private static func ogContent(_ property: String, in html: String) -> String? {
    guard !html.isEmpty else { return nil }
    let escaped = NSRegularExpression.escapedPattern(for: property)
    let patterns = [
      "<meta[^>]*(?:property|name)=[\"']\(escaped)[\"'][^>]*content=[\"']([^\"']*)[\"']",
      "<meta[^>]*content=[\"']([^\"']*)[\"'][^>]*(?:property|name)=[\"']\(escaped)[\"']",
    ]
    for pattern in patterns {
      guard
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
        let match = regex.firstMatch(
          in: html, options: [], range: NSRange(html.startIndex..., in: html)),
        match.numberOfRanges > 1,
        let range = Range(match.range(at: 1), in: html)
      else { continue }
      let value = Self.decodeHTMLEntities(String(html[range]))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty { return value }
    }
    return nil
  }

  private static func decodeHTMLEntities(_ value: String) -> String {
    var result = value
    let entities: [(String, String)] = [
      ("&amp;", "&"), ("&quot;", "\""), ("&#34;", "\""), ("&#39;", "'"),
      ("&#x27;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "),
    ]
    for (entity, replacement) in entities {
      result = result.replacingOccurrences(of: entity, with: replacement)
    }
    return result
  }
}

/// The quoted message inside a bubble.
///
/// What it is NOT, deliberately: Telegram's vertical colour rail with a name and a line of
/// text beside it, and not the rotated 24×24 reply arrow SVG that replaced it (an arrow
/// pointing at text it sits next to says nothing the position doesn't already say — it was
/// just ornament, and at 18pt a rotated arrow reads as a glitch).
///
/// What it is: **a fragment torn out of the other message.** The plate carries one chamfered
/// corner — a clipped edge where it was taken from — and its accent wash starts at that edge
/// and dissolves to the right, INTO the message you wrote. Identity is carried by colour and
/// by the tear, not by a glyph. No icon at any size, so nothing to misread.
private final class BubbleReplyPreviewView: UIView {
  private let gradientLayer = CAGradientLayer()
  private let plateMask = CAShapeLayer()
  private let titleLabel = UILabel()
  private let previewLabel = UILabel()
  private var accentColors: (UIColor, UIColor)?
  /// The clipped corner. Big enough to read as intentional at 36pt, small enough that the
  /// name never collides with it.
  private static let chamfer: CGFloat = 9.0
  private static let cornerRadius: CGFloat = 10.0

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    clipsToBounds = true
    layer.mask = plateMask

    gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
    gradientLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
    layer.insertSublayer(gradientLayer, at: 0)

    titleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
    titleLabel.numberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail
    addSubview(titleLabel)

    previewLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
    previewLabel.numberOfLines = 1
    previewLabel.lineBreakMode = .byTruncatingTail
    addSubview(previewLabel)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func reset() {
    titleLabel.text = nil
    previewLabel.text = nil
    accentColors = nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gradientLayer.colors = nil
    CATransaction.commit()
  }

  func configure(
    title: String,
    text: String,
    appearance: ChatListAppearance,
    isMe: Bool,
    accentColors: (UIColor, UIColor)? = nil
  ) {
    titleLabel.text = title
    previewLabel.text = text
    self.accentColors = accentColors
    applyAppearance(appearance, isMe: isMe)
  }

  func applyAppearance(_ appearance: ChatListAppearance, isMe: Bool) {
    let fallbackAccent =
      isMe
      ? (appearance.bubbleMeGradient.first ?? appearance.textColorMe)
      : appearance.bubbleThemColor
    let paletteStart = accentColors?.0 ?? fallbackAccent
    let paletteEnd = accentColors?.1 ?? paletteStart
    let titleColor = accentColors != nil
      ? paletteStart
      : (isMe ? appearance.textColorMe : appearance.textColorThem)
    let bodyColor = isMe ? appearance.textColorMe : appearance.textColorThem

    titleLabel.textColor = titleColor.withAlphaComponent(0.96)
    previewLabel.textColor = bodyColor.withAlphaComponent(0.62)

    // The wash is strongest at the torn edge and dissolves toward the right, so the quote
    // visibly recedes into the message it is attached to instead of sitting on top of it
    // as a solid tinted box.
    let bgAlpha: CGFloat = appearance.isDark ? 0.30 : 0.17
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gradientLayer.colors = [
      paletteStart.withAlphaComponent(bgAlpha).cgColor,
      paletteEnd.withAlphaComponent(bgAlpha * 0.28).cgColor,
    ]
    gradientLayer.locations = [0.0, 1.0]
    CATransaction.commit()
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    gradientLayer.frame = bounds
    plateMask.frame = bounds
    plateMask.path = Self.tornPlatePath(
      in: bounds, radius: Self.cornerRadius, chamfer: Self.chamfer
    ).cgPath

    // Text is inset past the chamfer so the clipped corner never crowds the name. The
    // arrow used to eat 17pt of a 36pt-tall block; that width goes back to the quote.
    let textX: CGFloat = 11.0
    let textW = max(1.0, bounds.width - textX - 8.0)
    let textTop = (bounds.height - 32.0) / 2.0
    titleLabel.frame = CGRect(x: textX, y: textTop, width: textW, height: 16.0)
    previewLabel.frame = CGRect(x: textX, y: titleLabel.frame.maxY, width: textW, height: 16.0)

    CATransaction.commit()
  }

  /// Rounded plate with the top-leading corner cut away — the edge it was torn from.
  private static func tornPlatePath(
    in rect: CGRect, radius: CGFloat, chamfer: CGFloat
  ) -> UIBezierPath {
    let r = min(radius, min(rect.width, rect.height) * 0.5)
    let c = min(chamfer, min(rect.width, rect.height) * 0.5)
    let path = UIBezierPath()
    path.move(to: CGPoint(x: rect.minX + c, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.minY + r),
      controlPoint: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX - r, y: rect.maxY),
      controlPoint: CGPoint(x: rect.maxX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX, y: rect.maxY - r),
      controlPoint: CGPoint(x: rect.minX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + c))
    path.close()
    return path
  }

}

final class BubbleLinkPreviewView: UIView {
  private let accentView = UIView()
  private let iconView = UIImageView()
  private let siteLabel = UILabel()
  private let titleLabel = UILabel()
  // Music-card mode (Telegram-style rich preview for SoundCloud/YouTube links).
  private let artworkView = UIImageView()
  private let playBadgeView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
  private let playGlyphView = UIImageView()
  private let descLabel = UILabel()
  private var isMusicCard = false
  private var hasUsablePreviewData = false
  private var currentArtworkURLString: String?
  private var currentURL: URL?
  private var currentAppearance = ChatListAppearance.current
  private var currentIsMe = false
  var onPreviewAvailabilityChange: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    layer.cornerRadius = 14.0
    layer.cornerCurve = .continuous
    layer.borderWidth = 1.0 / UIScreen.main.scale
    clipsToBounds = true

    accentView.isUserInteractionEnabled = false
    addSubview(accentView)

    iconView.contentMode = .scaleAspectFit
    iconView.clipsToBounds = true
    iconView.layer.cornerRadius = 8.0
    addSubview(iconView)

    siteLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
    siteLabel.numberOfLines = 1
    addSubview(siteLabel)

    titleLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
    titleLabel.numberOfLines = 2
    addSubview(titleLabel)

    artworkView.contentMode = .scaleAspectFill
    artworkView.clipsToBounds = true
    artworkView.layer.cornerRadius = 10.0
    artworkView.layer.cornerCurve = .continuous
    artworkView.isHidden = true
    addSubview(artworkView)

    playBadgeView.clipsToBounds = true
    playBadgeView.isUserInteractionEnabled = false
    playBadgeView.isHidden = true
    playGlyphView.image = UIImage(
      systemName: "play.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 22.0, weight: .bold)
    )
    playGlyphView.tintColor = .white
    playGlyphView.contentMode = .center
    playBadgeView.contentView.addSubview(playGlyphView)
    addSubview(playBadgeView)

    descLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
    descLabel.numberOfLines = 1
    descLabel.lineBreakMode = .byTruncatingTail
    descLabel.isHidden = true
    addSubview(descLabel)

    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    addGestureRecognizer(tap)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func reset() {
    currentURL = nil
    currentArtworkURLString = nil
    siteLabel.text = nil
    titleLabel.text = nil
    descLabel.text = nil
    artworkView.image = nil
    isMusicCard = false
    hasUsablePreviewData = false
    artworkView.isHidden = true
    playBadgeView.isHidden = true
    descLabel.isHidden = true
    iconView.isHidden = false
    titleLabel.numberOfLines = 2
    iconView.image = UIImage(systemName: "globe")
    iconView.contentMode = .scaleAspectFit
  }

  func applyAppearance(_ appearance: ChatListAppearance, isMe: Bool) {
    currentAppearance = appearance
    currentIsMe = isMe

    let accentColor = isMe
      ? (appearance.bubbleMeGradient.first ?? appearance.bubbleThemColor)
      : appearance.bubbleThemColor
    accentView.backgroundColor = accentColor.withAlphaComponent(0.94)
    layer.borderColor = accentColor.withAlphaComponent(appearance.isDark ? 0.34 : 0.20).cgColor
    backgroundColor = isMe
      ? UIColor.white.withAlphaComponent(appearance.isDark ? 0.14 : 0.22)
      : UIColor(white: appearance.isDark ? 1.0 : 0.0, alpha: appearance.isDark ? 0.08 : 0.05)
    siteLabel.textColor = accentColor.withAlphaComponent(0.96)
    titleLabel.textColor = isMe ? appearance.textColorMe : appearance.textColorThem
    descLabel.textColor = (isMe ? appearance.textColorMe : appearance.textColorThem)
      .withAlphaComponent(0.72)
    artworkView.backgroundColor = accentColor.withAlphaComponent(appearance.isDark ? 0.16 : 0.10)
    if iconView.image == nil || iconView.contentMode != .scaleAspectFill {
      iconView.image = UIImage(systemName: "globe")
      iconView.tintColor = accentColor.withAlphaComponent(0.96)
      iconView.backgroundColor = accentColor.withAlphaComponent(appearance.isDark ? 0.14 : 0.10)
      iconView.contentMode = .scaleAspectFit
    }
  }

  func configure(url: URL, appearance: ChatListAppearance, isMe: Bool) {
    let sameURL = currentURL?.absoluteString == url.absoluteString
    if !sameURL {
      currentArtworkURLString = nil
      artworkView.image = nil
      siteLabel.text = nil
      titleLabel.text = nil
      descLabel.text = nil
      hasUsablePreviewData = false
    }
    currentURL = url
    isMusicCard = bubbleIsMusicPreviewURL(url)
    applyAppearance(appearance, isMe: isMe)

    if isMusicCard {
      isHidden = false
      hasUsablePreviewData = true
      configureMusicCard(url: url, appearance: appearance, isMe: isMe, sameURL: sameURL)
      return
    }

    iconView.isHidden = false
    artworkView.isHidden = true
    playBadgeView.isHidden = true
    descLabel.isHidden = true
    titleLabel.numberOfLines = 2
    if !sameURL {
      iconView.image = UIImage(systemName: "globe")
      iconView.contentMode = .scaleAspectFit
    }
    iconView.tintColor = (isMe
      ? (appearance.bubbleMeGradient.first ?? appearance.bubbleThemColor)
      : appearance.bubbleThemColor).withAlphaComponent(0.96)
    if iconView.contentMode != .scaleAspectFill {
      iconView.backgroundColor = iconView.tintColor.withAlphaComponent(appearance.isDark ? 0.14 : 0.10)
    }
    isHidden = !hasUsablePreviewData

    BubbleLinkPreviewStore.shared.fetch(url: url) { [weak self] data in
      guard let self, self.currentURL?.absoluteString == url.absoluteString else { return }
      guard let data else {
        self.hasUsablePreviewData = false
        self.isHidden = true
        self.onPreviewAvailabilityChange?()
        return
      }
      self.siteLabel.text = data.site
      self.titleLabel.text = data.title
      if let icon = data.icon {
        self.iconView.image = icon
        self.iconView.backgroundColor = .clear
        self.iconView.contentMode = .scaleAspectFill
      } else {
        self.iconView.image = UIImage(systemName: "globe")
        self.iconView.contentMode = .scaleAspectFit
      }
      self.hasUsablePreviewData = true
      self.isHidden = false
      self.setNeedsLayout()
    }
  }

  private func configureMusicCard(
    url: URL,
    appearance: ChatListAppearance,
    isMe: Bool,
    sameURL: Bool
  ) {
    iconView.isHidden = true
    artworkView.isHidden = false
    playBadgeView.isHidden = false
    descLabel.isHidden = false
    titleLabel.numberOfLines = 1
    // Keep existing artwork when re-configuring the same link (avoids empty-then-pop
    // on every cell rebind / setRows while OG metadata is still warm).
    if !sameURL {
      artworkView.image = nil
      currentArtworkURLString = nil
      siteLabel.text = bubbleMusicPreviewFallbackSite(for: url)
      titleLabel.text = bubblePreviewTitleFallback(for: url)
      descLabel.text = nil
    }

    BubbleMusicPreviewStore.shared.fetch(url: url) { [weak self] data in
      guard let self, self.currentURL?.absoluteString == url.absoluteString else { return }
      // Telegram order: site, title, description (artist).
      self.siteLabel.text = data.site
      self.titleLabel.text = data.title
      self.descLabel.text = data.desc
      guard let imageURLString = data.imageURLString else { return }
      if self.currentArtworkURLString == imageURLString, self.artworkView.image != nil {
        return
      }
      self.currentArtworkURLString = imageURLString
      // Prefer in-memory cover immediately (no empty flash).
      let warmKey = chatMusicCoverCacheKey(imageURLString)
      if let warm = chatMediaImageCache.object(forKey: warmKey as NSString) {
        self.artworkView.image = warm
        return
      }
      _ = chatLoadMusicCover(urlString: imageURLString) { [weak self] image in
        guard let self, self.currentArtworkURLString == imageURLString else { return }
        self.artworkView.image = image
        self.setNeedsLayout()
      }
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    // Telegram card uses a thin left accent bar.
    accentView.frame = CGRect(x: 0.0, y: 0.0, width: 3.0, height: bounds.height)

    if isMusicCard {
      // Match Telegram reference: art inset ~10–12pt from card edge (accent bar is 3pt),
      // nearly-square cover, 56pt centered play, Source/Title/Artist tight under art.
      let artX: CGFloat = 10.0
      let artWidth = max(1.0, bounds.width - artX - 10.0)
      let artSide = min(bubbleMusicLinkArtworkHeight, artWidth)
      artworkView.frame = CGRect(
        x: artX, y: bubbleMusicLinkArtTop, width: artWidth, height: artSide
      )
      artworkView.layer.cornerRadius = 12.0
      artworkView.layer.cornerCurve = .continuous
      let badgeSize: CGFloat = 56.0
      playBadgeView.frame = CGRect(
        x: artworkView.frame.midX - badgeSize * 0.5,
        y: artworkView.frame.midY - badgeSize * 0.5,
        width: badgeSize,
        height: badgeSize
      )
      playBadgeView.layer.cornerRadius = badgeSize * 0.5
      // Nudge the play triangle slightly right so it looks optically centered.
      playGlyphView.frame = CGRect(x: 2.0, y: 0.0, width: badgeSize, height: badgeSize)
      siteLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
      titleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
      descLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
      let textY = artworkView.frame.maxY + bubbleMusicLinkArtBottomGap
      siteLabel.frame = CGRect(x: artX, y: textY, width: artWidth, height: 18.0)
      titleLabel.frame = CGRect(
        x: artX, y: siteLabel.frame.maxY + 2.0, width: artWidth, height: 20.0
      )
      descLabel.frame = CGRect(
        x: artX, y: titleLabel.frame.maxY + 1.0, width: artWidth, height: 18.0
      )
      return
    }

    siteLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
    let leadingInset: CGFloat = 14.0
    let iconSize: CGFloat = 24.0
    iconView.frame = CGRect(
      x: leadingInset,
      y: floor((bounds.height - iconSize) * 0.5),
      width: iconSize,
      height: iconSize
    )

    let textX = iconView.frame.maxX + 10.0
    let textWidth = max(1.0, bounds.width - textX - 14.0)
    siteLabel.frame = CGRect(x: textX, y: 12.0, width: textWidth, height: 14.0)
    titleLabel.frame = CGRect(
      x: textX,
      y: siteLabel.frame.maxY + 4.0,
      width: textWidth,
      height: bounds.height - siteLabel.frame.maxY - 16.0
    )
  }

  @objc private func handleTap() {
    guard let currentURL else { return }
    InAppBrowserViewController.present(url: currentURL)
  }
}

/// True while an agent turn is a bare "thinking" state — streaming, no final answer, and
/// nothing renderable in the feed yet (no tool/task steps, no narration text nodes, no
/// answer body). This is the only state that should hug + center; the moment a step or
/// prose arrives the bubble expands to the full agent width like every other turn.
/// Cheap row-level equivalent of `chatMessage(from:).isStreaming`'s live gate: the full
/// mapping reports a live turn only when `row.isStreamingText || <a running node>`
/// (see `isLiveTurn` in `VibeAgentKitMap.chatMessage(from:)`). Hot per-row predicates
/// use it to skip building the whole AgentKit message — which E2E-decrypts action
/// details — for the settled rows that dominate a transcript. Keep in sync with
/// `isLiveTurn`; a false positive here only costs the full (correct) check.
// Internal, not fileprivate: `presentationSeedMessageHeight` decides measure-vs-estimate
// with the SAME liveness test the plate reserve uses, so the two can't disagree about
// which rows are mid-stream.
func agentTurnRowCouldBeLive(_ row: ChatListRow) -> Bool {
  row.isStreamingText
    || row.agentProgressNodes.contains { $0.status.lowercased() == "running" }
}

func agentTurnBubbleIsCompactThinking(_ row: ChatListRow) -> Bool {
  guard agentTurnRowCouldBeLive(row) else { return false }
  let message = VibeAgentKitMap.chatMessage(from: row)
  guard message.isStreaming, !message.hasFinalResponseText else { return false }
  let hasRenderableProgress = message.progressItems.contains { item in
    if item.itemType == "text" {
      return !item.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    // A bare "Thinking" placeholder node (no command / output detail) is NOT real content:
    // the chat header already shows the thinking state, so the row stays suppressed until an
    // actual tool step or narration arrives. This kills the momentary "Thinking" bubble that
    // pops in for a few seconds and then vanishes + shifts the layout when the first real
    // chunk lands (mirrors the full-page view's isPlaceholderThinking filter).
    return !isPlaceholderThinkingProgressItem(item)
  }
  if hasRenderableProgress { return false }
  return resoloAssistantDisplayText(for: message)
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .isEmpty
}

/// A no-detail "Thinking"/"Thinking…" progress node — the placeholder the CLI emits while
/// the model is only reasoning. Real thinking narration (one carrying messageContent /
/// messagePreview) is NOT a placeholder and stays renderable. Mirrors
/// `VibeAgentConversationViewController.isPlaceholderThinking`.
func isPlaceholderThinkingProgressItem(_ item: VibeAgentKitProgressItem) -> Bool {
  let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  let messageContent = item.messageContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  let messagePreview = item.messagePreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  let hasDetail = !messageContent.isEmpty || !messagePreview.isEmpty
  return !hasDetail && (label == "thinking" || label == "thinking...")
}

/// Whether the agent bubble should render the body view's loader line. Only a SETTLED
/// turn shows it — the tappable "Worked for Xs · N steps" summary (same affordance as
/// the full agent view; tap opens the glass detail sheet via `onLoaderTap` →
/// `openAgentTurnDetail`). Mid-run the loader stays hidden: the bubble's live feed
/// already carries the working state at its edge, so a second shimmer line at the top
/// would duplicate it. Must be passed identically to `measuredHeight` and
/// `configure(row:)` or the measured bubble height won't match what renders.
func agentTurnBubbleShowsWorkedSummary(_ row: ChatListRow) -> Bool {
  // Settled row (see agentTurnRowCouldBeLive): isStreaming is false in the full
  // mapping, so this is exactly `!(false && …)` without the per-row decrypt cost.
  guard agentTurnRowCouldBeLive(row) else { return true }
  let message = VibeAgentKitMap.chatMessage(from: row)
  return !(message.isStreaming && !message.hasFinalResponseText)
}

/// Width the compact "thinking" bubble should hug: the shimmer line (icon + label) plus a
/// little slack, capped by the caller at maxContentWidth. Mirrors the loader's own text
/// choice + font (systemFont 14.5 medium) so the bubble tracks the shimmer without
/// clipping it.
func agentTurnCompactHugWidth(_ row: ChatListRow) -> CGFloat {
  let message = VibeAgentKitMap.chatMessage(from: row)
  // Same display mapping the shimmer uses — a live thinking node reads
  // "Thinking · 1.2k tokens", so the hug width must measure that full string.
  let label = message.progressItems.last(where: { $0.itemType != "text" })
    .map { vibeAgentKitProgressDisplayLabel($0) }
    ?? message.progress.last
    ?? "Thinking"
  let font = UIFont.systemFont(ofSize: 14.5, weight: .medium)
  let textWidth = (label as NSString).size(withAttributes: [.font: font]).width
  // activity icon (15) + stack spacing (6) + small slack so the shimmer never clips.
  let affordance: CGFloat = 15.0 + 6.0 + 14.0
  return ceil(textWidth) + affordance
}

/// A completed, plain one-line answer should not inherit the wide workspace shell used
/// by a live Read/Edit/Run feed. Settled progress/runtime metadata is allowed because it
/// renders as the compact "Worked" summary; only active work keeps the full width.
func agentTurnSettledTextHugWidth(_ row: ChatListRow, maxContentWidth: CGFloat) -> CGFloat? {
  let message = VibeAgentKitMap.chatMessage(from: row)
  let hasRunningProgress = message.progressItems.contains {
    vibeAgentKitRunningStepStatuses.contains(($0.status ?? "").lowercased())
  }
  guard !message.isStreaming,
    message.hasFinalResponseText,
    !hasRunningProgress
  else {
    return nil
  }

  let text = resoloAssistantDisplayText(for: message)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard !text.isEmpty,
    text.count <= 84,
    !text.contains(where: { $0.isNewline }),
    !text.contains("```"),
    !text.contains("`"),
    !text.contains("**"),
    !text.contains("__"),
    !text.contains("[")
  else {
    return nil
  }

  let font = UIFont.systemFont(ofSize: 16.0, weight: .regular)
  let measuredWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
  // Do not compress something that already needs most of the normal reading width.
  guard measuredWidth < maxContentWidth * 0.72 else { return nil }
  // Leave room for the settled "Worked · N steps" affordance below the answer.
  return min(maxContentWidth, max(196.0, measuredWidth + 10.0))
}

/// Width a short, single-line conversational agent answer should hug so its bubble tracks
/// the text instead of drawing a full-width empty shell around "Done" / "No track found".
/// Multiline prose deliberately falls through to the normal full reading width: measuring
/// each source line unwrapped makes lists and short Markdown paragraphs look artificially
/// narrow, then forces their real rendered text to wrap a second time inside that width.
/// Qualifies only when there is NO tool/progress feed, runtime card, or action bar.
func agentTurnPlainTextHugWidth(_ row: ChatListRow, maxContentWidth: CGFloat) -> CGFloat? {
  guard row.isAgentMessage,
    row.agentRuntime == nil,
    row.agentProgressNodes.isEmpty,
    (row.agentActionsEnc?.isEmpty ?? true)
  else { return nil }
  let text = trimmedBubbleText(row)
  // Structured / multiline answers need the full reading width. Apart from fixing list
  // wrapping, this keeps measure == render while a streamed answer grows into paragraphs.
  guard !text.isEmpty,
    text.count <= 84,
    !text.contains(where: { $0.isNewline }),
    !text.contains("```"),
    !text.contains("`"),
    !text.contains("**"),
    !text.contains("__"),
    !text.contains("[")
  else { return nil }
  let font = UIFont.systemFont(ofSize: 16.0, weight: .regular)
  let measuredWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
  guard measuredWidth > 0, measuredWidth < maxContentWidth * 0.72 else { return nil }
  // +16 slack so a slightly-wider glyph (bold, emoji) never forces an extra wrap.
  return min(maxContentWidth, max(bubbleMinWidth, measuredWidth + 16.0))
}

/// Width a NATIVE ("Vibe AI") turn should hug while it is showing ONLY a single running
/// progress-narration step (e.g. "Resolving SoundCloud…" → "Found · …"). Without this the
/// turn snaps to the full agent workspace width (~336pt) around one short line — the big
/// fixed-width empty box the user reported. We hug the narration like the thinking pill
/// (`agentTurnCompactHugWidth`) so it grows width→height instead. Returns nil (→ full width)
/// for anything ambiguous, so every risky case defaults safe.
///
/// HARD native-only gate: the id must be a built-in agent turn ("<uuid>-turn") and NOT a
/// bridge/stream/lan session row — the Claude/Codex rich multi-step / diff / card feeds share
/// this renderer and MUST keep full width. Also bails on any real tool step (file/diff/read
/// range, subagent, detail body), any runtime/actions/music-card, more than one node, or a
/// non-running / multi-line label. Intro prose arrives as extra `.text` nodes (see the
/// interleaved-prose builder), so a prose+step turn has >1 node and correctly falls through.
func agentTurnSingleStepHugWidth(_ row: ChatListRow, maxContentWidth: CGFloat) -> CGFloat? {
  let id = row.messageId ?? ""
  guard id.hasSuffix("-turn"),
    !id.hasPrefix("bridge-"), !id.hasPrefix("stream-"), !id.hasPrefix("lan-")
  else { return nil }
  // Only the LIVE narration phase; a settled turn renders the "Worked · N steps" summary.
  guard row.isStreamingText,
    row.agentRuntime == nil,
    (row.agentActionsEnc?.isEmpty ?? true),
    (row.musicCoverURL?.isEmpty ?? true),
    row.agentProgressNodes.count == 1,
    let node = row.agentProgressNodes.first,
    // Hug across the whole live narration: the step flips running→done ("Resolving…"→
    // "Found · …") WHILE the turn is still streaming, so accepting only "running" would
    // snap it to full width mid-stream. Any non-error live status hugs; a failed step
    // falls through to the full width (it renders its own error affordance).
    ["running", "done", "complete", "completed", "success"].contains(node.status.lowercased())
  else { return nil }
  // Must be a plain spinner+label step — reject anything that needs the full workspace:
  // file/diff/read-range tool steps, subagent grouping, or a detail body.
  guard (node.kind ?? "").lowercased() != "task",
    node.parentId == nil, node.subagentType == nil,
    node.target == nil, node.added == nil, node.removed == nil,
    node.start == nil, node.end == nil,
    (node.detail?.isEmpty ?? true)
  else { return nil }
  let label = node.label.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !label.isEmpty, !label.contains(where: { $0.isNewline }) else { return nil }
  // Reuse the thinking-pill measurement (label + icon affordance). Height is measured at this
  // same width downstream, so a hair-off estimate costs at most a tiny wrap, never a clip.
  let hug = agentTurnCompactHugWidth(row)
  // A label that already needs the full reading width should just use it (never wrap a
  // single line inside a pill).
  guard hug > 0, hug < maxContentWidth else { return nil }
  return min(maxContentWidth, max(bubbleMinWidth, hug))
}

/// Live-computer band under an agent turn: fixed one line, so it is a plain constant in
/// every height path (docs/row-height-formulas.md §1.5). Never let it wrap.
let agentTurnComputerBandHeight: CGFloat = 26.0
let agentTurnComputerBandTopGap: CGFloat = 8.0

/// What the band shows for one turn: browser host + page, or terminal + command label.
struct AgentTurnComputerBand: Equatable {
  let isShell: Bool
  let primary: String
  let secondary: String
  let live: Bool
  let showsTakeControl: Bool
}

/// Host without `www.`; empty when the string is not an absolute URL.
func agentComputerBandHost(_ raw: String) -> String {
  let host = URL(string: raw)?.host ?? ""
  return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

private func agentTurnLastComputerNode(_ row: ChatListRow) -> ChatListRow.AgentProgressNode? {
  row.agentProgressNodes.last { node in
    let tool = node.tool ?? ""
    return tool.hasPrefix("computer_") || tool.hasPrefix("browser_")
  }
}

/// The chat's live computer while the turn is running; once it settles, that turn's own
/// last computer step — so a finished turn freezes the band instead of losing it.
func agentTurnComputerBandState(_ row: ChatListRow) -> AgentTurnComputerBand? {
  guard bubbleUsesAgentTurnContent(row) else { return nil }
  if agentTurnRowCouldBeLive(row),
    let state = ChatEngine.shared.latestAgentComputer(chatId: row.chatId)
  {
    let primary = state.isShell ? state.title : state.host
    if !primary.isEmpty {
      return AgentTurnComputerBand(
        isShell: state.isShell,
        primary: primary,
        secondary: state.isShell ? "" : state.title,
        live: state.live,
        showsTakeControl: state.live && state.agentHoldsControl)
    }
  }
  guard let node = agentTurnLastComputerNode(row) else { return nil }
  let isBrowser = (node.tool ?? "").hasPrefix("browser_")
  let host = agentComputerBandHost(node.target ?? node.label)
  let usesHost = isBrowser && !host.isEmpty
  let primary = usesHost ? host : node.label
  guard !primary.isEmpty else { return nil }
  return AgentTurnComputerBand(
    isShell: !isBrowser,
    primary: primary,
    secondary: usesHost ? node.label : (node.target ?? ""),
    live: false,
    showsTakeControl: false)
}

/// Constant the computer band adds to this row's bubble. Applied identically by
/// `measureMessageBubbleLayout` and `ChatListView.presentationSeedMessageHeight`.
func agentTurnComputerBandReserve(_ row: ChatListRow) -> CGFloat {
  agentTurnComputerBandState(row) == nil
    ? 0.0 : agentTurnComputerBandTopGap + agentTurnComputerBandHeight
}

/// Single width decision for agent-turn bubbles (measure == render).
///
/// - Full `maxContentWidth` when the row genuinely needs the workspace (bridge/stream/lan
///   id, runtime card, actions, >1 real non-text progress node, or a diff/file/subagent/
///   detail node).
/// - Otherwise hug natural content width (widest body line + narration / thinking pill),
///   floored at `bubbleMinWidth` and capped at `maxContentWidth`.
func agentTurnContentWidth(_ row: ChatListRow, maxContentWidth: CGFloat) -> CGFloat {
  // Compact "thinking" shell: always hug the shimmer, even on bridge rows.
  if agentTurnBubbleIsCompactThinking(row) {
    return min(maxContentWidth, max(bubbleMinWidth, agentTurnCompactHugWidth(row)))
  }

  let id = row.messageId ?? ""
  let isBridgeFamily =
    id.hasPrefix("bridge-") || id.hasPrefix("stream-") || id.hasPrefix("lan-")
  let realNonTextNodes = row.agentProgressNodes.filter {
    ($0.kind ?? "").lowercased() != "text"
  }
  let hasWorkspaceShape = row.agentProgressNodes.contains { node in
    let kind = (node.kind ?? "").lowercased()
    if kind == "task" || kind == "diff" || kind == "file" { return true }
    if node.subagentType != nil || node.parentId != nil { return true }
    if node.target != nil || node.added != nil || node.removed != nil { return true }
    if node.start != nil || node.end != nil { return true }
    if !(node.detail?.isEmpty ?? true) { return true }
    return false
  }
  let needsWorkspace =
    isBridgeFamily
    || row.agentRuntime != nil
    || !(row.agentActionsEnc?.isEmpty ?? true)
    || realNonTextNodes.count > 1
    || hasWorkspaceShape
  if needsWorkspace {
    return maxContentWidth
  }

  // Natural hug: reuse the old specialized hug helpers as building blocks, then fall
  // back to measuring the body + any single narration/thinking label.
  if let plainHug = agentTurnPlainTextHugWidth(row, maxContentWidth: maxContentWidth) {
    return plainHug
  }
  if let settledHug = agentTurnSettledTextHugWidth(row, maxContentWidth: maxContentWidth) {
    return settledHug
  }
  if let stepHug = agentTurnSingleStepHugWidth(row, maxContentWidth: maxContentWidth) {
    return stepHug
  }

  let bodyFont = UIFont.systemFont(ofSize: 16.0, weight: .regular)
  let pillFont = UIFont.systemFont(ofSize: 14.5, weight: .medium)
  var natural: CGFloat = 0
  let bodyText = trimmedBubbleText(row)
  if !bodyText.isEmpty, !bodyText.contains("```") {
    let widest = bodyText.split(whereSeparator: { $0.isNewline }).reduce(CGFloat(0)) {
      max($0, ceil((String($1) as NSString).size(withAttributes: [.font: bodyFont]).width))
    }
    natural = max(natural, widest + 16.0)
  }
  for node in row.agentProgressNodes {
    let label = node.label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty else { continue }
    if (node.kind ?? "").lowercased() == "text" {
      let widest = label.split(whereSeparator: { $0.isNewline }).reduce(CGFloat(0)) {
        max($0, ceil((String($1) as NSString).size(withAttributes: [.font: bodyFont]).width))
      }
      natural = max(natural, widest + 16.0)
    } else {
      // activity icon (15) + stack spacing (6) + slack — same affordance as compact hug.
      let pill =
        ceil((label as NSString).size(withAttributes: [.font: pillFont]).width) + 15.0 + 6.0
        + 14.0
      natural = max(natural, pill)
    }
  }
  if natural > 0 {
    return min(maxContentWidth, max(bubbleMinWidth, natural))
  }
  return maxContentWidth
}

func measureMessageBubbleLayout(
  row: ChatListRow, rowWidth: CGFloat, agentTurnState: AgentTurnBubbleState = AgentTurnBubbleState()
)
  -> ChatMessageBubbleLayoutMetrics
{
  if row.kind == .message, row.messageType == "agent_actions" {
    let actionWidth = max(1.0, rowWidth - (bubbleSideMargin * 2.0))
    return ChatMessageBubbleLayoutMetrics(
      bubbleWidth: actionWidth,
      bubbleHeight: 36.0,
      messageWidth: actionWidth,
      textHeight: 0.0,
      bodyHeight: 36.0,
      metaWidth: 0.0,
      contentWidth: actionWidth,
      mediaHeight: 0.0,
      isMediaLayout: false,
      inlineAttachmentHeight: 0.0,
      hasInlineAttachment: false,
      replyPreviewHeight: 0.0,
      hasReplyPreview: false,
      previewHeight: 0.0,
      hasLinkPreview: false,
      usesBottomMetaLayout: false,
      usesRichTextLayout: false
    )
  }

  let previewCandidateURL = bubblePreviewCandidateURL(for: row)
  let usesMusicLinkPreview = previewCandidateURL.map { bubbleIsMusicPreviewURL($0) } ?? false
  let usesExpandedURLWidth = previewCandidateURL != nil && !usesMusicLinkPreview
  let widthFactor = usesExpandedURLWidth ? bubbleURLOnlyMaxWidthFactor : bubbleMaxWidthFactor
  let maxBubbleWidth = floor(rowWidth * widthFactor)
  let maxContentWidth = max(1.0, maxBubbleWidth - (bubbleHorizontalPadding * 2.0))
  let messageContentWidthLimit =
    usesMusicLinkPreview
    ? min(
      maxContentWidth,
      max(
        1.0,
        floor(rowWidth * bubbleMusicPreviewMaxWidthFactor) - (bubbleHorizontalPadding * 2.0)))
    : maxContentWidth
  let meta = bubbleMetaWidths(for: row)

  if bubbleUsesAgentTurnContent(row) {
    // Agent turns get a wider, tighter-padded shell than a plain text bubble (see the
    // agentTurn* constants) so the dense step/narration/diff feed has room to breathe.
    let agentMaxBubbleWidth = floor(rowWidth * agentTurnMaxWidthFactor)
    let maxContentWidth = max(1.0, agentMaxBubbleWidth - (agentTurnHorizontalPadding * 2.0))
    // ONE width rule for measure + render (see agentTurnContentWidth).
    let compact = agentTurnBubbleIsCompactThinking(row)
    let contentWidth = agentTurnContentWidth(row, maxContentWidth: maxContentWidth)
    // Colors don't affect layout metrics, so a fixed appearance is fine for measurement
    // even though the live render uses the trait-matched one. Measure at the SAME width we
    // set below so the height matches what actually renders.
    let previewHeight = VibeAgentTurnContentView.measuredHeight(
      row: row,
      appearance: .fallback,
      availableWidth: contentWidth,
      isProgressExpanded: agentTurnState.isProgressExpanded,
      isRuntimeExpanded: agentTurnState.isRuntimeExpanded,
      expandedStepIds: agentTurnState.expandedStepIds,
      streamingStartDate: agentTurnState.streamingStartDate,
      showsLoaderView: agentTurnBubbleShowsWorkedSummary(row)
    )
    let reactionSize = reactionStripMeasuredSize(
      row.reactions, maxWidth: max(1.0, agentMaxBubbleWidth - 12.0),
      showsCount: row.isGroupOrChannel)
    let reactionHeightOffset = reactionStripHeightOffset(
      reactionSize, bottomPadding: agentTurnVerticalPadding)
    let bubbleWidth = min(
      agentMaxBubbleWidth,
      max(
        bubbleMinWidth,
        contentWidth + (agentTurnHorizontalPadding * 2.0),
        reactionSize.width + 12.0))
    // Same tall-content collapse as plain text bubbles, but only once the turn SETTLES —
    // a live feed keeps growing and pinning it to the cap would fight the stream (and the
    // list's bottom pin). Content stays full; plate height caps and soft-fades.
    let tallToggleVisible =
      previewHeight > tallBubbleCollapseTriggerHeight && agentTurnBubbleShowsWorkedSummary(row)
    let tallCollapsed = tallToggleVisible && !agentTurnState.tallExpanded
    let contentHeight = previewHeight
    let bubbleContentHeight =
      tallCollapsed ? min(previewHeight, tallBubbleCollapsedContentHeight) : previewHeight
    // Glass expand/collapse chip lives OUTSIDE the plate (list overlay).
    // Floor at 44 only when a live loader/placeholder is actually visible (compact
    // thinking shell, or a live streaming placeholder with no body yet). Settled bodies
    // self-size so we never keep a 44→34 settle shift or an artificial user↔agent gap.
    // Mid-stream tool gaps keep the session-grace isStreaming latch: an empty live turn
    // still floors so the cell does not collapse between steps.
    let bodyPlusPadding =
      bubbleContentHeight
      + agentTurnVerticalPadding + agentTurnVerticalPadding + reactionHeightOffset
    let isLiveStreaming =
      row.isStreamingText || agentTurnRowCouldBeLive(row)
    let needsHeightFloor =
      compact
      || (isLiveStreaming && bubbleContentHeight < 1.0)
      || (isLiveStreaming && !agentTurnBubbleShowsWorkedSummary(row) && bubbleContentHeight < 44.0)
    let settledBubbleHeight = needsHeightFloor ? max(44.0, bodyPlusPadding) : bodyPlusPadding
    // A live turn is sized with headroom, a settled one exactly (see
    // agentTurnStreamingHeightBlock). The slack lands BELOW the body: the content view is
    // top-aligned at `bubbleFrame.minY + agentTurnVerticalPadding` and keeps its own
    // measured `textHeight`, so pre-expanding the plate never moves text that is already
    // on screen — the next tokens simply fill space that is already there.
    // Band reserve rides OUTSIDE the streaming quantization so it stays an exact constant
    // instead of being swallowed by the 48pt block.
    let bubbleHeight =
      (isLiveStreaming
        ? agentTurnStreamingReservedHeight(settledBubbleHeight)
        : settledBubbleHeight) + agentTurnComputerBandReserve(row)
    // DIAGNOSTIC (live-turn empty-bubble): compare what the sizing pass measured against
    // what the render pass draws. An empty on-screen bubble with items>0 here means the
    // content exists but is clipped/misplaced; h≈44 with items>0 means the measurement
    // itself collapsed.
    if row.isStreamingText || (row.status ?? "").lowercased() == "running" {
      VibeDebugLog.log(
        "[AgentMeasure] id=%@ compact=%@ items=%d width=%.0f previewH=%.1f bubbleH=%.1f",
        String((row.messageId ?? "-").suffix(14)),
        compact ? "Y" : "N",
        row.agentProgressNodes.count,
        contentWidth, previewHeight, bubbleHeight)
    }
    var metrics = ChatMessageBubbleLayoutMetrics(
      bubbleWidth: bubbleWidth,
      bubbleHeight: bubbleHeight,
      messageWidth: contentWidth,
      textHeight: contentHeight,
      bodyHeight: contentHeight,
      metaWidth: 0.0,
      contentWidth: contentWidth,
      mediaHeight: 0.0,
      isMediaLayout: false,
      inlineAttachmentHeight: 0.0,
      hasInlineAttachment: false,
      replyPreviewHeight: 0.0,
      hasReplyPreview: false,
      previewHeight: 0.0,
      hasLinkPreview: false,
      usesBottomMetaLayout: true,
      usesRichTextLayout: false,
      agentTurnCentered: compact
    )
    metrics.tallToggleVisible = tallToggleVisible
    metrics.tallCollapsed = tallCollapsed
    metrics.tallOuterToggleReserve = 0.0
    return metrics
  }

  if usesTransparentAgentStreamingLayout(row) {
    let bubbleWidth = max(1.0, rowWidth - (bubbleSideMargin * 2.0))
    let messageWidth = max(1.0, bubbleWidth - (bubbleHorizontalPadding * 2.0))
    let usesRichTextLayout = bubbleUsesBlockLayout(row)
    let previewHeight = bubbleRowPreviewHeight(for: row)
    let textHeight: CGFloat
    if usesRichTextLayout {
      textHeight = measureBubbleRichText(for: row, availableWidth: messageWidth).height
    } else {
      let displayText = bubbleDisplayAttributedString(for: row, font: bubbleMessageFont)
      let textRect = displayText.boundingRect(
        with: CGSize(width: messageWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        context: nil
      )
      textHeight = ceil(textRect.height)
    }
    let bodyHeight = textHeight + (previewHeight > 0.0 ? (bubbleLinkPreviewSpacing + previewHeight) : 0.0)
    let bubbleHeight = max(36.0, bodyHeight + bubbleTopPadding + bubbleBottomPadding)
    return ChatMessageBubbleLayoutMetrics(
      bubbleWidth: bubbleWidth,
      bubbleHeight: bubbleHeight,
      messageWidth: messageWidth,
      textHeight: textHeight,
      bodyHeight: bodyHeight,
      metaWidth: 0.0,
      contentWidth: messageWidth,
      mediaHeight: 0.0,
      isMediaLayout: false,
      inlineAttachmentHeight: 0.0,
      hasInlineAttachment: false,
      replyPreviewHeight: 0.0,
      hasReplyPreview: false,
      previewHeight: previewHeight,
      hasLinkPreview: previewHeight > 0.0,
      usesBottomMetaLayout: previewHeight > 0.0 || usesRichTextLayout,
      usesRichTextLayout: usesRichTextLayout
    )
  }

  switch row.visualKind {
  case .voice, .video, .videoNote, .media, .document, .sticker:
    var targetWidth: CGFloat
    var mediaHeight: CGFloat
    var mediaAspectWasUnknown = false
    let limitsMediaWidth = row.visualKind == .video || row.visualKind == .media
    let isFullBleed = usesFullBleedMediaLayout(row)
    let mediaBubbleWidthLimit =
      limitsMediaWidth
      ? min(maxBubbleWidth, floor(rowWidth * bubbleMediaMaxWidthFactor))
      : maxBubbleWidth
    let mediaContentWidthLimit =
      limitsMediaWidth
      ? max(
        1.0,
        mediaBubbleWidthLimit - (isFullBleed ? 0.0 : bubbleHorizontalPadding * 2.0))
      : maxContentWidth
    switch row.visualKind {
    case .voice:
      if usesAudioMetadataVoiceLayout(row) {
        // Compact music cell: play plate + title/artist (not the tall link-preview card).
        let title = resolvedAudioVoiceTitle(row)
        let detail = resolvedAudioVoiceStaticDetail(row)
        let titleFont = UIFont.systemFont(ofSize: 15, weight: .semibold)
        let detailFont = UIFont.systemFont(ofSize: 13, weight: .regular)
        let titleW = ceil(
          (title as NSString).size(withAttributes: [.font: titleFont]).width)
        let detailW = ceil(
          (detail as NSString).size(withAttributes: [.font: detailFont]).width)
        let textW = max(titleW, detailW)
        // 52 play + 8 gap + text + trailing meta room
        let contentW = 52.0 + 8.0 + textW + 8.0
        targetWidth = min(maxContentWidth, max(160.0 + meta.total, contentW + meta.total))
        // Extra height so the VAD halo around the play plate is not vertically clipped.
        mediaHeight = 68.0
      } else {
        let dur = max(1.0, min(30.0, row.duration ?? 1.0))
        let frac = CGFloat((Double(dur) - log(Double(max(2.0, dur)))) / 15.0)
        let minW = 100.0 + meta.total
        targetWidth = minW + max(0.0, min(1.0, frac)) * (maxContentWidth - minW)
        mediaHeight = 60.0
      }
    case .videoNote:
      let side = videoNoteRenderedSide(
        expanded: agentTurnState.videoNoteExpanded,
        rowWidth: rowWidth,
        maxBubbleWidth: maxBubbleWidth)
      targetWidth = side
      mediaHeight = side
    case .document:
      // حباب به‌اندازهٔ نام فایل کشیده می‌شود، نه همیشه تا آخرِ عرضِ ممکن —
      // یک نامِ کوتاه داخل حبابی تمام‌عرض، همان چیزی است که «تمیز نیست» به نظر
      // می‌رسید.
      let nameWidth = (chatDocumentDisplayName(row) as NSString).size(
        withAttributes: [.font: UIFont.systemFont(ofSize: 15, weight: .semibold)]
      ).width
      let detailWidth = (chatDocumentTypeLabel(row) as NSString).size(
        withAttributes: [.font: UIFont.systemFont(ofSize: 13, weight: .regular)]
      ).width
      let textWidth = max(nameWidth, detailWidth + 78.0)
      targetWidth = min(maxContentWidth, ceil(documentPreviewSide + 12.0 + textWidth) + 2.0)
      mediaHeight = documentRowHeight
    case .video, .media, .sticker:
      let gridCount = chatMediaGridImageCount(row)
      if gridCount > 1 {
        targetWidth = mediaContentWidthLimit
        mediaHeight = chatMediaStackHeight(for: row, width: targetWidth)
      } else if let naturalSize = resolvedMediaNaturalSize(for: row),
        naturalSize.width > 1.0,
        naturalSize.height > 1.0
      {
        // A size from the blur thumb (route 5) keeps the height provisional, never exact.
        mediaAspectWasUnknown =
          row.mediaUrl?.isEmpty == false && chatMediaNaturalSizeIsThumbDerived(for: row.mediaUrl)
        let ratio = max(0.2, min(5.0, naturalSize.height / naturalSize.width))
        let sizeLimit: CGFloat =
          row.visualKind == .sticker ? stickerMaxDisplayWidth : mediaContentWidthLimit
        let minWidth: CGFloat = row.visualKind == .sticker ? stickerMinDisplaySide : 120.0
        let minHeight: CGFloat = row.visualKind == .sticker ? stickerMinDisplaySide : 84.0
        targetWidth = max(minWidth, min(sizeLimit, naturalSize.width))
        mediaHeight = max(minHeight, targetWidth * ratio)
        let heightLimit: CGFloat = row.visualKind == .sticker ? stickerMaxDisplayHeight : 380.0
        if mediaHeight > heightLimit {
          mediaHeight = heightLimit
          targetWidth = mediaHeight / ratio
        }
      } else if row.visualKind == .sticker {
        // Sticker default: compact square like Telegram, but smaller than generic media.
        targetWidth = stickerDefaultDisplaySide
        mediaHeight = stickerDefaultDisplaySide
        mediaAspectWasUnknown = row.mediaUrl?.isEmpty == false
      } else {
        // The unknown-aspect fallback. NOT a square any more.
        //
        // A square was the worst available guess. Full width on a 430pt screen is a ~336pt
        // box, while real photos land between 84pt (wide panorama) and 380pt (the portrait
        // cap) — so the guess was wrong by up to 252pt (`slot-repair … slack=+252`) and the
        // correction that followed was the largest single layout shift in the app. Every
        // `[shift]` line from the 2026-08-07 device run is one of these: ±200pt, `where=ABOVE`,
        // moving content the reader was looking at, and worst of all during a send.
        //
        // 4:3 landscape is the modal photo shape, so it is both a better guess and a far
        // cheaper mistake: the worst case drops from 252pt to roughly 60pt, and the common
        // case is near zero.
        //
        // This path is now rare by construction. It is reached only when the message carries
        // NEITHER dimensions NOR a thumbnail — and those two are produced together by the
        // same block in `ChatEngine.sendMessage`, which used to skip anything whose declared
        // type was not image/gif. A photo shared as a FILE therefore arrived with both
        // missing. That gate now keys off the file header instead of the type, so new sends
        // always carry a shape and never reach this line.
        //
        // Still provisional: unlike a bundled sticker (whose default box is the final
        // answer), this media can resolve, and a stale guess that is never corrected is a
        // permanently mis-shaped photo. The goal here is to make the correction small
        // enough not to be seen, not to abandon it.
        targetWidth = max(120.0, mediaContentWidthLimit)
        mediaHeight = max(84.0, min(380.0, targetWidth * 0.75))
        mediaAspectWasUnknown = row.mediaUrl?.isEmpty == false
      }
    case .text:
      targetWidth = maxContentWidth
      mediaHeight = 0.0
    }

    let isTransparentSticker = isTransparentStickerMessage(row)
    let metaTopSpacing = effectiveMetaTopSpacing(for: row)
    let contentWidth = min(mediaContentWidthLimit, targetWidth)
    let hasMediaCaption = hasMediaCaptionLayout(row) && !isTransparentSticker
    let isEdgeCaption = usesEdgeMediaCaptionLayout(row)
    let captionAttributedText =
      hasMediaCaption
      ? bubbleDisplayAttributedString(for: row, font: bubbleMessageFont)
      : nil
    // Edge layout: the bubble hugs the media (hairline inset), so the caption must wrap
    // inside the media width minus the regular horizontal text padding — otherwise a
    // long line would spill past the bubble edge.
    let captionMaxWidth =
      isEdgeCaption
      ? max(1.0, contentWidth + mediaCaptionEdgeInset * 2.0 - bubbleHorizontalPadding * 2.0)
      : contentWidth
    let captionRect =
      captionAttributedText?.boundingRect(
        with: CGSize(width: captionMaxWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        context: nil
      ) ?? .zero
    let captionWidth = min(captionMaxWidth, ceil(captionRect.width))
    let captionHeight = ceil(captionRect.height)
    let messageWidth =
      hasMediaCaption
      ? (isEdgeCaption ? captionMaxWidth : max(contentWidth, captionWidth))
      : contentWidth
    let reactionSize = reactionStripMeasuredSize(
      row.reactions, maxWidth: max(1.0, maxBubbleWidth - 12.0),
      showsCount: row.isGroupOrChannel)
    let bodyHeight: CGFloat
    var bubbleWidth: CGFloat
    let bubbleHeight: CGFloat
    if isTransparentSticker {
      bodyHeight = mediaHeight + metaTopSpacing + bubbleMetaHeight
      bubbleWidth = max(meta.total, contentWidth)
      bubbleHeight =
        bodyHeight + reactionStripHeightOffset(reactionSize, bottomPadding: 0.0)
    } else {
      let isVoice = row.visualKind == .voice
      let captionBlockHeight: CGFloat
      if hasMediaCaption && !isVoice && !isFullBleed {
        captionBlockHeight =
          (isEdgeCaption ? mediaCaptionTopGap : 8.0) + captionHeight + bubbleMetaTopSpacing
          + bubbleMetaHeight
      } else if isFullBleed || isVoice {
        captionBlockHeight = 0.0
      } else {
        captionBlockHeight = metaTopSpacing + bubbleMetaHeight
      }
      // Video note: time + duration ride a line UNDER the circle (Telegram), so the row
      // reserves that line instead of pinning chrome inside the circular clip.
      let circleMetaBlock: CGFloat =
        row.visualKind == .videoNote ? (metaTopSpacing + bubbleMetaHeight) : 0.0
      bodyHeight =
        (isFullBleed || isVoice)
        ? (mediaHeight + circleMetaBlock) : (mediaHeight + captionBlockHeight)
      if isEdgeCaption {
        // Edge-to-edge media: the bubble is the image plus a hairline border.
        bubbleWidth = max(bubbleMinWidth, contentWidth + mediaCaptionEdgeInset * 2.0)
      } else {
        bubbleWidth =
          isFullBleed
          ? max(bubbleMinWidth, contentWidth)
          : max(bubbleMinWidth, max(contentWidth, messageWidth) + (bubbleHorizontalPadding * 2.0))
      }
      // Compact voice/music: tight pads so the play-row stays short.
      let topPad: CGFloat =
        isVoice ? 2.0 : (isEdgeCaption ? mediaCaptionEdgeInset : bubbleTopPadding)
      let bottomPad: CGFloat =
        isVoice ? 7.0 : (isEdgeCaption ? mediaCaptionBottomPadding : bubbleBottomPadding)
      bubbleHeight =
        isFullBleed
        ? max(56.0, bodyHeight + reactionStripHeightOffset(reactionSize, bottomPadding: 0.0))
        : max(
          isVoice ? 66.0 : 48.0,
          bodyHeight + topPad + bottomPad
            + reactionStripHeightOffset(reactionSize, bottomPadding: bottomPad))
    }
    bubbleWidth = min(mediaBubbleWidthLimit, max(bubbleWidth, reactionSize.width + 12.0))
    var metrics = ChatMessageBubbleLayoutMetrics(
      bubbleWidth: bubbleWidth,
      bubbleHeight: bubbleHeight,
      messageWidth: messageWidth,
      textHeight: hasMediaCaption ? captionHeight : 0.0,
      bodyHeight: bodyHeight,
      metaWidth: meta.total,
      contentWidth: contentWidth,
      mediaHeight: mediaHeight,
      isMediaLayout: true,
      inlineAttachmentHeight: 0.0,
      hasInlineAttachment: false,
      replyPreviewHeight: 0.0,
      hasReplyPreview: false,
      previewHeight: 0.0,
      hasLinkPreview: false,
      usesBottomMetaLayout: false,
      usesRichTextLayout: false
    )
    metrics.mediaAspectWasUnknown = mediaAspectWasUnknown
    return metrics

  case .text:
    break
  }

  let showsReplyPreview = hasReplyPreview(row)
  let showsInlineAttachment = hasInlineAttachment(row)
  let usesRichTextLayout = bubbleUsesBlockLayout(row)
  let previewHeight = bubbleRowPreviewHeight(for: row)
  let previewMinWidth = bubbleRowPreviewMinWidth(for: row)
  let usesRTLColumn = usesRTLColumnLayout(row) && !showsInlineAttachment && !usesRichTextLayout && previewHeight <= 0.0
  let replyPreviewHeight = showsReplyPreview ? bubbleReplyPreviewHeight : 0.0
  let replyPreviewBlockHeight =
    showsReplyPreview ? (bubbleReplyPreviewHeight + bubbleReplyPreviewSpacing) : 0.0
  var usesBottomMetaLayout = usesRichTextLayout || previewHeight > 0.0 || usesRTLColumn
  let font =
    row.messageType == "typing"
    ? UIFont.systemFont(ofSize: 13, weight: .regular) : bubbleMessageFont
  let measureText: (CGFloat) -> (width: CGFloat, height: CGFloat) = { availableWidth in
    if usesRichTextLayout {
      let measured = measureBubbleRichText(for: row, availableWidth: availableWidth)
      return (
        min(availableWidth, max(measured.maxWidth, previewHeight > 0.0 ? previewMinWidth : 0.0)),
        measured.height
      )
    }
    let displayText = bubbleDisplayAttributedString(for: row, font: font)
    let textRect = displayText.boundingRect(
      with: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    return (min(availableWidth, ceil(textRect.width)), ceil(textRect.height))
  }
  let textMaxWidth: CGFloat =
    showsInlineAttachment || usesBottomMetaLayout
    ? messageContentWidthLimit
    : max(1.0, messageContentWidthLimit - meta.total - bubbleMetaInlineSpacing)
  var (textWidth, fullTextHeight) = measureText(textMaxWidth)
  // One shared tall-content rule for user AND agent text bubbles: past the trigger the
  // bubble collapses to the cap and gains a leading meta-row double-chevron (see the
  // tallBubble* constants). Typing placeholders and inline-attachment rows are exempt
  // (the attachment body-height arm below doesn't reserve the control).
  let tallToggleVisible =
    fullTextHeight > tallBubbleCollapseTriggerHeight
    && row.messageType != "typing"
    && !showsInlineAttachment
  if tallToggleVisible && !usesBottomMetaLayout {
    // A tall bubble puts meta under the body (bottom-meta layout) so the chevron can
    // share the meta row without fighting an inline timestamp — re-measure at the full
    // width that layout grants the text (the collapse decision can't flip: the trigger
    // dwarfs the few points of width difference).
    usesBottomMetaLayout = true
    (textWidth, fullTextHeight) = measureText(messageContentWidthLimit)
  }
  let tallCollapsed = tallToggleVisible && !agentTurnState.tallExpanded
  // Content always lays out at full height so expand is pure Y reveal (no reflow).
  // Bubble height alone uses the collapsed cap; soft fade mask shows "there's more".
  let tallCollapsedLineCount = max(
    1.0, (tallBubbleCollapsedContentHeight / font.lineHeight).rounded(.down))
  let collapsedCapHeight = ceil(tallCollapsedLineCount * font.lineHeight)
  let textHeight = fullTextHeight
  let bubbleTextHeight =
    tallCollapsed ? min(fullTextHeight, collapsedCapHeight) : fullTextHeight
  let tallToggleReserve: CGFloat = 0.0
  let attachmentBodyHeight: CGFloat = showsInlineAttachment ? inlineAttachmentHeight : 0.0
  let desiredContentWidth: CGFloat
  let replyPreviewWidth: CGFloat
  if showsReplyPreview {
    let titleWidth = measuredTextWidth(
      replyPreviewTitle(for: row), font: UIFont.systemFont(ofSize: 13, weight: .semibold))
    let textWidth = measuredTextWidth(
      replyPreviewText(for: row), font: UIFont.systemFont(ofSize: 13, weight: .regular))
    replyPreviewWidth = min(
      messageContentWidthLimit,
      max(bubbleReplyPreviewMinWidth, max(titleWidth, textWidth) + 24.0)
    )
  } else {
    replyPreviewWidth = 0.0
  }
  if showsInlineAttachment {
    let attachmentTitle = inlineAttachmentTitle(for: row)
    let attachmentWidth =
      min(
        messageContentWidthLimit,
        max(
          168.0,
          measuredTextWidth(attachmentTitle, font: UIFont.systemFont(ofSize: 13, weight: .semibold))
            + 62.0)
      )
    desiredContentWidth = max(textWidth, attachmentWidth, replyPreviewWidth)
  } else if usesBottomMetaLayout {
    let rtlTailSideReserve = usesRTLColumn && row.isMe ? bubbleRTLTailSideReserve : 0.0
    let coreContentWidth = max(
      textWidth,
      usesRTLColumn ? meta.total : 0.0,
      previewHeight > 0.0 ? previewMinWidth : 0.0,
      replyPreviewWidth
    )
    desiredContentWidth = max(
      coreContentWidth + rtlTailSideReserve,
      coreContentWidth
    )
  } else {
    desiredContentWidth = max(textWidth + bubbleMetaInlineSpacing + meta.total, replyPreviewWidth)
  }
  let reactionSize = reactionStripMeasuredSize(
    row.reactions,
    maxWidth: max(1.0, messageContentWidthLimit + (bubbleHorizontalPadding * 2.0) - 12.0),
    showsCount: row.isGroupOrChannel)
  // Timestamp rides the reaction row (LTR and RTL) when there is no link preview.
  let metaRidesReactionRow =
    reactionSize.height > 0.0 && !showsInlineAttachment && previewHeight <= 0.0
  let reactionRowWidth =
    metaRidesReactionRow
    ? reactionSize.width + bubbleMetaInlineSpacing + meta.total
    : reactionSize.width
  let contentWidth = max(
    meta.total,
    min(messageContentWidthLimit, max(desiredContentWidth, reactionRowWidth)))
  let appliedRTLTailSideReserve =
    usesRTLColumn && row.isMe
    ? min(bubbleRTLTailSideReserve, max(0.0, contentWidth - max(textWidth, meta.total, replyPreviewWidth)))
    : 0.0
  let messageWidth =
    showsInlineAttachment || usesBottomMetaLayout
    ? max(1.0, contentWidth - appliedRTLTailSideReserve)
    : max(1.0, contentWidth - meta.total - bubbleMetaInlineSpacing)
  // Plate height uses the (possibly capped) body; metrics.textHeight stays full.
  let bottomMetaLine: CGFloat =
    metaRidesReactionRow ? 0.0 : (bubbleMetaTopSpacing + bubbleMetaHeight)
  let bodyHeight =
    showsInlineAttachment
    ? replyPreviewBlockHeight + max(bubbleTextHeight, 0.0) + inlineAttachmentSpacing
      + attachmentBodyHeight + bubbleMetaTopSpacing + bubbleMetaHeight
    : usesBottomMetaLayout
    ? replyPreviewBlockHeight + max(bubbleTextHeight, 0.0) + tallToggleReserve
      + (previewHeight > 0.0 ? (bubbleLinkPreviewSpacing + previewHeight) : 0.0)
      + bottomMetaLine
    : replyPreviewBlockHeight + max(bubbleTextHeight, bubbleMetaHeight)
  let reactionHeightOffset = reactionStripHeightOffset(
    reactionSize, bottomPadding: bubbleBottomPadding)
  // No fudge: the plate is exactly the content box plus its two paddings. Shaving 4pt here
  // made the bubble narrower than the content it advertises, so the body label (laid out at
  // contentX + contentWidth) ended 4pt to the right of the meta (right-aligned to
  // maxX - padding). Invisible for LTR — left-aligned body, right-aligned meta, both inside
  // — but a right-aligned RTL body hugs that edge, so its text and its ✓ sat on two
  // different right edges.
  let bubbleWidth = max(bubbleMinWidth, contentWidth + (bubbleHorizontalPadding * 2.0))
  let bubbleHeight = max(
    34.0, bodyHeight + bubbleTopPadding + bubbleBottomPadding + reactionHeightOffset)
  var metrics = ChatMessageBubbleLayoutMetrics(
    bubbleWidth: bubbleWidth,
    bubbleHeight: bubbleHeight,
    messageWidth: messageWidth,
    textHeight: textHeight,
    bodyHeight: bodyHeight,
    metaWidth: meta.total,
    contentWidth: contentWidth,
    mediaHeight: 0.0,
    isMediaLayout: false,
    inlineAttachmentHeight: attachmentBodyHeight,
    hasInlineAttachment: showsInlineAttachment,
    replyPreviewHeight: replyPreviewHeight,
    hasReplyPreview: showsReplyPreview,
    previewHeight: previewHeight,
    hasLinkPreview: previewHeight > 0.0,
    usesBottomMetaLayout: usesBottomMetaLayout,
    usesRichTextLayout: usesRichTextLayout
  )
  metrics.tallToggleVisible = tallToggleVisible
  metrics.tallCollapsed = tallCollapsed
  metrics.tallOuterToggleReserve = 0.0
  return metrics
}

private func bubbleRoundedPath(
  rect: CGRect,
  topLeft: CGFloat,
  topRight: CGFloat,
  bottomRight: CGFloat,
  bottomLeft: CGFloat
) -> UIBezierPath {
  let width = max(1.0, rect.width)
  let height = max(1.0, rect.height)
  let radiusLimit = min(width, height) * 0.5
  let tl = min(max(0.0, topLeft), radiusLimit)
  let tr = min(max(0.0, topRight), radiusLimit)
  let br = min(max(0.0, bottomRight), radiusLimit)
  let bl = min(max(0.0, bottomLeft), radiusLimit)

  let path = UIBezierPath()
  path.move(to: CGPoint(x: tl, y: 0.0))
  path.addLine(to: CGPoint(x: width - tr, y: 0.0))
  path.addArc(
    withCenter: CGPoint(x: width - tr, y: tr),
    radius: tr,
    startAngle: 3.0 * .pi / 2.0,
    endAngle: 0.0,
    clockwise: true
  )
  path.addLine(to: CGPoint(x: width, y: height - br))
  path.addArc(
    withCenter: CGPoint(x: width - br, y: height - br),
    radius: br,
    startAngle: 0.0,
    endAngle: .pi / 2.0,
    clockwise: true
  )
  path.addLine(to: CGPoint(x: bl, y: height))
  path.addArc(
    withCenter: CGPoint(x: bl, y: height - bl),
    radius: bl,
    startAngle: .pi / 2.0,
    endAngle: .pi,
    clockwise: true
  )
  path.addLine(to: CGPoint(x: 0.0, y: tl))
  path.addArc(
    withCenter: CGPoint(x: tl, y: tl),
    radius: tl,
    startAngle: .pi,
    endAngle: 3.0 * .pi / 2.0,
    clockwise: true
  )
  path.close()
  return path
}

/// Circular water-fill transfer control. Byte progress rises from the bottom.
final class BubbleUploadProgressView: UIView {
  private let fillLayer = CAShapeLayer()
  private let waterHostLayer = CALayer()
  private let waterMaskLayer = CAShapeLayer()
  private let waterFillLayer = CALayer()
  private let trackLayer = CAShapeLayer()
  private let iconView = UIImageView()
  /// Progress below this is treated as connecting, not a stuck fill.
  private let realProgressThreshold: CGFloat = 0.05
  private var displayedWater: CGFloat = 0
  private var laidOutBowl = CGRect.zero
  private var isUploading = false
  private var needsDownload = false
  private var isDownloading = false
  private var uploadProgress: CGFloat?
  private var lastResolvedUploadProgress: CGFloat?
  private var downloadProgress: CGFloat?
  private var lastResolvedDownloadProgress: CGFloat?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear

    fillLayer.fillColor = UIColor(white: 0.0, alpha: 0.58).cgColor
    waterFillLayer.backgroundColor = UIColor.white.withAlphaComponent(0.34).cgColor
    waterFillLayer.anchorPoint = CGPoint(x: 0.5, y: 1.0)
    waterHostLayer.mask = waterMaskLayer
    waterHostLayer.addSublayer(waterFillLayer)

    trackLayer.fillColor = UIColor.clear.cgColor
    trackLayer.strokeColor = UIColor(white: 1.0, alpha: 0.20).cgColor
    trackLayer.lineWidth = 1.5

    layer.addSublayer(fillLayer)
    layer.addSublayer(waterHostLayer)
    layer.addSublayer(trackLayer)

    iconView.image = UIImage(systemName: "xmark")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
    iconView.tintColor = .white
    iconView.contentMode = .scaleAspectFit
    iconView.isHidden = true
    addSubview(iconView)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let fillDiameter = max(1.0, min(bounds.width, bounds.height) - 6.0)
    let fillFrame = CGRect(
      x: floor((bounds.width - fillDiameter) * 0.5),
      y: floor((bounds.height - fillDiameter) * 0.5),
      width: fillDiameter,
      height: fillDiameter
    )
    fillLayer.frame = bounds
    fillLayer.path = UIBezierPath(ovalIn: fillFrame).cgPath
    waterHostLayer.frame = bounds
    waterMaskLayer.frame = bounds
    waterMaskLayer.path = UIBezierPath(ovalIn: fillFrame).cgPath
    trackLayer.frame = bounds
    trackLayer.path = UIBezierPath(ovalIn: fillFrame.insetBy(dx: 0.75, dy: 0.75)).cgPath
    iconView.frame = CGRect(
      x: floor((bounds.width - 16.0) * 0.5),
      y: floor((bounds.height - 16.0) * 0.5),
      width: 16.0,
      height: 16.0
    )
    laidOutBowl = fillFrame
    layoutWaterFill(level: displayedWater)
  }

  /// `progress == nil` (or no real bytes yet) renders an indeterminate smooth arc
  /// spinner; a real fraction fills the path while the arc keeps spinning.
  func setUploadState(isUploading: Bool, progress: Double?) {
    if isUploading {
      needsDownload = false
      isDownloading = false
      downloadProgress = nil
      lastResolvedDownloadProgress = nil
    }
    let resolvedProgress: CGFloat?
    if isUploading {
      if let raw = progress.map({ CGFloat($0) }), raw.isFinite, raw >= realProgressThreshold {
        let clamped = max(0.0, min(1.0, raw))
        lastResolvedUploadProgress = clamped
        resolvedProgress = clamped
      } else if let lastResolvedUploadProgress, lastResolvedUploadProgress >= realProgressThreshold {
        resolvedProgress = lastResolvedUploadProgress
      } else {
        resolvedProgress = nil
      }
    } else {
      resolvedProgress = nil
      lastResolvedUploadProgress = nil
    }

    let progressChanged =
      abs((self.uploadProgress ?? -1) - (resolvedProgress ?? -1)) >= 0.002
    if self.isUploading == isUploading, !progressChanged {
      return
    }

    self.isUploading = isUploading
    self.uploadProgress = resolvedProgress
    updateUploadRingVisual()
  }

  func setDownloadState(needsDownload: Bool, isDownloading: Bool, progress: Double?) {
    guard !isUploading else { return }

    let resolvedProgress: CGFloat?
    if isDownloading {
      if let raw = progress.map({ CGFloat($0) }), raw.isFinite, raw >= realProgressThreshold {
        let clamped = max(0.0, min(1.0, raw))
        // Monotonic progress so reconfigure never snaps the ring back to empty.
        if let last = lastResolvedDownloadProgress, clamped + 0.002 < last {
          resolvedProgress = last
        } else {
          lastResolvedDownloadProgress = clamped
          resolvedProgress = clamped
        }
      } else if let lastResolvedDownloadProgress, lastResolvedDownloadProgress >= realProgressThreshold
      {
        resolvedProgress = lastResolvedDownloadProgress
      } else {
        resolvedProgress = nil
      }
    } else if !needsDownload {
      resolvedProgress = nil
      lastResolvedDownloadProgress = nil
    } else {
      resolvedProgress = nil
      lastResolvedDownloadProgress = nil
    }

    // Ignore idle flicker while still "needs download" during an active transfer.
    if self.isDownloading && !isDownloading && needsDownload {
      return
    }

    let progressChanged =
      abs((self.downloadProgress ?? -1) - (resolvedProgress ?? -1)) >= 0.002
    if self.needsDownload == needsDownload, self.isDownloading == isDownloading, !progressChanged {
      return
    }

    self.needsDownload = needsDownload
    self.isDownloading = isDownloading
    self.downloadProgress = resolvedProgress
    updateDownloadRingVisual()
  }

  private func updateUploadRingVisual() {
    guard isUploading else {
      resetRingVisual()
      return
    }

    let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
    iconView.image = UIImage(systemName: "xmark", withConfiguration: config)
    iconView.tintColor = .white
    iconView.isHidden = false

    applyWaterProgress(currentWaterProgress(), animated: true)
  }

  private func updateDownloadRingVisual() {
    guard needsDownload, isDownloading else {
      resetRingVisual()
      return
    }

    iconView.isHidden = true
    applyWaterProgress(currentWaterProgress(), animated: true)
  }

  private func resetRingVisual() {
    displayedWater = 0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layoutWaterFill(level: 0)
    CATransaction.commit()
    iconView.isHidden = true
  }

  private func currentWaterProgress() -> CGFloat? {
    if isUploading { return uploadProgress }
    if needsDownload && isDownloading { return downloadProgress }
    return nil
  }

  private func bowlRect() -> CGRect {
    let fillDiameter = max(1.0, min(bounds.width, bounds.height) - 6.0)
    return CGRect(
      x: floor((bounds.width - fillDiameter) * 0.5),
      y: floor((bounds.height - fillDiameter) * 0.5),
      width: fillDiameter,
      height: fillDiameter
    )
  }

  private func layoutWaterFill(level: CGFloat) {
    let bowl = bowlRect()
    let clamped = max(0.0, min(1.0, level))
    waterFillLayer.position = CGPoint(x: bowl.midX, y: bowl.maxY)
    waterFillLayer.bounds = CGRect(
      x: 0, y: 0, width: max(1.0, bowl.width), height: max(0.5, bowl.height * clamped))
  }

  private func applyWaterProgress(_ progress: CGFloat?, animated: Bool, force: Bool = false) {
    let target: CGFloat
    if let progress {
      target = max(0.04, min(1.0, progress))
    } else if isUploading || (needsDownload && isDownloading) {
      target = 0.22
    } else {
      target = 0
    }
    guard force || abs(displayedWater - target) >= 0.008 else { return }
    displayedWater = target
    let apply = { self.layoutWaterFill(level: target) }
    if animated, bounds.width > 8 {
      CATransaction.begin()
      CATransaction.setAnimationDuration(0.32)
      CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
      apply()
      CATransaction.commit()
    } else {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      apply()
      CATransaction.commit()
    }
  }
}

/// HTTP headers some media CDNs require. SoundCloud's HLS CDN hotlink-protects with a
/// Referer/User-Agent gate — the server's yt-dlp sends these, so the client must match or
/// the CDN returns 403 "Forbidden".
enum VoicePlayProgressViewSourceHeaders {
  static let browserUserAgent =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0"

  static func headers(for url: URL) -> [String: String]? {
    guard let host = url.host?.lowercased() else { return nil }
    if host.contains("soundcloud") {
      return [
        "User-Agent": browserUserAgent,
        "Referer": "https://soundcloud.com/",
        "Origin": "https://soundcloud.com",
      ]
    }
    return nil
  }
}

final class VoicePlayProgressView: UIView {
  private let fluidVisualizer = FluidVADVisualizer()
  private let fillView = UIView()
  private let artworkImageView = UIImageView()
  private let artworkOverlayView = UIView()
  private let iconView = UIImageView()
  private let ringProgressLayer = CAShapeLayer()
  // Download state lives on a small corner badge over the artwork (bottom-right),
  // never on the center glyph — the center is always the play/pause control.
  private let downloadBadgeView = UIView()
  private let downloadBadgeIconView = UIImageView()
  private let downloadBadgeRingLayer = CAShapeLayer()
  private let uploadProgressAnimationKey = "voice.upload.progress"
  private let uploadSpinAnimationKey = "voice.upload.spin"
  private let badgeSpinAnimationKey = "voice.badge.spin"
  private let badgeProgressAnimationKey = "voice.badge.progress"
  private var iconTintColor = ChatListAppearance.current.accent
  private var ringTintColor = ChatListAppearance.current.accent
  /// Fill color of the corner download badge — the appearance accent (falls back to ringTint).
  private var badgeTintColor = ChatListAppearance.current.accent
  /// Dominant color pulled from the artwork; tints the fluid halo so it reads as the cover.
  private var artworkAccentColor: UIColor?
  /// When true the glyph is punched OUT of the filled circle instead of drawn on top,
  /// so the bubble itself shows through it. Used on my own bubbles, where the plate is
  /// the text color and the icon must read as the bubble color.
  private var knockoutIcon = false
  private var currentIconName: String?
  private var lastKnockoutMaskKey: String?
  private var isUploading = false
  private var needsDownload = false
  private var isDownloading = false
  private var downloadFailed = false
  private var uploadProgress: CGFloat?
  private var lastResolvedUploadProgress: CGFloat?
  private var downloadProgress: CGFloat?
  private let minimumUploadProgress: CGFloat = 0.027

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = true
    backgroundColor = .clear
    // Fluid paints behind the plate and slightly outside it — never clip.
    clipsToBounds = false

    fluidVisualizer.isUserInteractionEnabled = false
    fluidVisualizer.alpha = 0
    // BEHIND fill/artwork so VAD is never on top of the cover.
    insertSubview(fluidVisualizer, at: 0)

    fillView.isUserInteractionEnabled = false
    fillView.backgroundColor = UIColor(white: 1.0, alpha: 0.96)
    fillView.layer.cornerCurve = .continuous
    fillView.clipsToBounds = true
    addSubview(fillView)

    artworkImageView.isHidden = true
    artworkImageView.contentMode = .scaleAspectFill
    artworkImageView.clipsToBounds = true
    fillView.addSubview(artworkImageView)

    artworkOverlayView.isHidden = true
    artworkOverlayView.isUserInteractionEnabled = false
    artworkOverlayView.backgroundColor = UIColor(white: 0.0, alpha: 0.18)
    fillView.addSubview(artworkOverlayView)

    ringProgressLayer.fillColor = UIColor.clear.cgColor
    // Center ring is upload-only now (download moved to the corner badge).
    ringProgressLayer.strokeColor = UIColor(white: 0.55, alpha: 0.85).cgColor
    ringProgressLayer.lineWidth = 2.6
    ringProgressLayer.lineCap = .round
    ringProgressLayer.strokeStart = 0.0
    ringProgressLayer.strokeEnd = 0.0
    layer.addSublayer(ringProgressLayer)

    iconView.contentMode = .scaleAspectFit
    addSubview(iconView)

    // Corner download badge — a hit-through overlay above the plate.
    downloadBadgeView.isUserInteractionEnabled = false
    downloadBadgeView.isHidden = true
    downloadBadgeView.layer.cornerCurve = .continuous
    addSubview(downloadBadgeView)

    downloadBadgeIconView.contentMode = .center
    downloadBadgeIconView.tintColor = .white
    downloadBadgeIconView.isUserInteractionEnabled = false
    downloadBadgeView.addSubview(downloadBadgeIconView)

    downloadBadgeRingLayer.fillColor = UIColor.clear.cgColor
    downloadBadgeRingLayer.strokeColor = UIColor.white.cgColor
    downloadBadgeRingLayer.lineWidth = 2.0
    downloadBadgeRingLayer.lineCap = .round
    downloadBadgeRingLayer.strokeStart = 0.0
    downloadBadgeRingLayer.strokeEnd = 0.0
    downloadBadgeView.layer.addSublayer(downloadBadgeRingLayer)

    setPlaybackState(isPlaying: false, progress: 0.0)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    clipsToBounds = false
    // Plate inset so VAD can pulse outside without being edge-clipped.
    let diameter = max(1.0, min(bounds.width, bounds.height) - 6.0)
    let fillFrame = CGRect(
      x: floor((bounds.width - diameter) * 0.5),
      y: floor((bounds.height - diameter) * 0.5),
      width: diameter,
      height: diameter
    )
    fillView.frame = fillFrame
    fillView.layer.cornerRadius = diameter * 0.5
    artworkImageView.frame = fillView.bounds
    artworkImageView.layer.cornerRadius = fillView.layer.cornerRadius
    artworkOverlayView.frame = fillView.bounds
    artworkOverlayView.layer.cornerRadius = fillView.layer.cornerRadius

    // Match the plate; scale animation expands outside (parent clipsToBounds = false).
    fluidVisualizer.activePushMultiplier = 0.15
    fluidVisualizer.frame = fillView.frame

    let ringRadius = max(2.0, (diameter * 0.5) + 1.8)
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let ringPath = UIBezierPath(
      arcCenter: center,
      radius: ringRadius,
      startAngle: -.pi / 2,
      endAngle: (.pi * 3.0) / 2.0,
      clockwise: true)
    ringProgressLayer.frame = bounds
    ringProgressLayer.path = ringPath.cgPath

    iconView.frame = CGRect(
      x: floor((bounds.width - 20.0) * 0.5),
      y: floor((bounds.height - 20.0) * 0.5),
      width: 20.0,
      height: 20.0
    )

    // Corner badge: bottom-right, tucked just inside the plate edge.
    let badgeSize: CGFloat = 19.0
    downloadBadgeView.frame = CGRect(
      x: fillFrame.maxX - badgeSize - 0.5,
      y: fillFrame.maxY - badgeSize - 0.5,
      width: badgeSize,
      height: badgeSize
    )
    downloadBadgeView.layer.cornerRadius = badgeSize * 0.5
    downloadBadgeIconView.frame = downloadBadgeView.bounds
    let badgeRingPath = UIBezierPath(
      arcCenter: CGPoint(x: badgeSize * 0.5, y: badgeSize * 0.5),
      radius: (badgeSize * 0.5) - 2.0,
      startAngle: -.pi / 2,
      endAngle: (.pi * 3.0) / 2.0,
      clockwise: true)
    // Set bounds + position (NOT frame) so a live rotation transform on the spinner is never
    // disturbed — setting `.frame` under a transform recomputes it and made the arc flicker
    // every layout pass. Disable implicit actions so geometry changes never animate.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    downloadBadgeRingLayer.bounds = downloadBadgeView.bounds
    downloadBadgeRingLayer.position = CGPoint(
      x: downloadBadgeView.bounds.midX,
      y: downloadBadgeView.bounds.midY
    )
    downloadBadgeRingLayer.path = badgeRingPath.cgPath
    CATransaction.commit()

    refreshIconKnockout()
  }

  /// Every input of the last `applyStyle` that actually landed.
  ///
  /// `cellForItemAt` re-applies appearance on every dequeue, and the five values are
  /// identical the overwhelming majority of the time — the appearance only genuinely
  /// changes when the user picks a new theme. Comparing them is far cheaper than a
  /// `tintColor` re-render, three `CAShapeLayer` fill writes and a knockout rebuild.
  private struct VoicePlateStyle: Equatable {
    let fill: UIColor
    let iconTint: UIColor
    let ringTint: UIColor
    let badgeTint: UIColor
    let knockout: Bool
  }
  private var lastAppliedPlateStyle: VoicePlateStyle?

  func applyStyle(
    fillColor: UIColor,
    iconTint: UIColor,
    ringTint: UIColor,
    badgeTint: UIColor? = nil,
    knockoutIcon: Bool = false
  ) {
    let style = VoicePlateStyle(
      fill: fillColor,
      iconTint: iconTint,
      ringTint: ringTint,
      badgeTint: badgeTint ?? ringTint,
      knockout: knockoutIcon
    )
    if style == lastAppliedPlateStyle {
      // The glyph and the plate size can change with no color changing at all, and the
      // knockout is keyed on exactly those — so it still gets its chance to notice.
      // It is a cache hit when nothing moved.
      refreshIconKnockout()
      return
    }
    lastAppliedPlateStyle = style
    fillView.backgroundColor = fillColor
    iconTintColor = iconTint
    ringTintColor = ringTint
    badgeTintColor = badgeTint ?? ringTint
    self.knockoutIcon = knockoutIcon
    iconView.tintColor = resolvedIconTintColor()
    ringProgressLayer.strokeColor = ringTint.cgColor
    refreshFluidColor()
    refreshIconKnockout()
    // Badge fill tracks the appearance accent; refresh it whenever the style changes.
    updateDownloadBadge()
    if isUploading {
      updateUploadRingVisual()
    }
  }

  func setArtworkImage(_ image: UIImage?) {
    artworkImageView.image = image
    let hasArtwork = image != nil
    artworkImageView.isHidden = !hasArtwork
    artworkOverlayView.isHidden = !hasArtwork
    artworkAccentColor = image.flatMap { VoicePlayProgressView.dominantColor(of: $0) }
    refreshFluidColor()
    iconView.tintColor = resolvedIconTintColor()
    // Artwork fills the plate, so there is no plate color left to punch through to —
    // the glyph goes back to being drawn on top (white, per `resolvedIconTintColor`).
    refreshIconKnockout()
  }

  /// Dynamic fluid tint: cover dominant color when present, else ring/accent tint.
  private func refreshFluidColor() {
    if let accent = artworkAccentColor {
      fluidVisualizer.applyColor(accent.withAlphaComponent(0.40))
    } else {
      fluidVisualizer.applyColor(ringTintColor.withAlphaComponent(0.35))
    }
  }

  private var knockoutActive: Bool {
    knockoutIcon && artworkImageView.image == nil
  }

  /// Knockout masks, shared by every cell in the app.
  ///
  /// The mask is a pure alpha punch-out — the plate circle with the glyph erased from it
  /// — so it depends on nothing but the symbol and the two sizes, never on color and
  /// never on which cell is asking. Rendering it per cell meant a `UIGraphicsImageRenderer`
  /// pass inside `cellForItemAt` every time a reused cell crossed from a their-bubble to
  /// a mine-bubble; there are only a handful of distinct keys in the whole app.
  private static let knockoutMaskCache = NSCache<NSString, UIImage>()

  /// Rebuild the punched-out plate. The mask is the filled circle with the glyph
  /// erased out of it, so whatever is behind the button (the bubble) reads as the icon.
  private func refreshIconKnockout() {
    guard knockoutActive, let glyph = iconView.image, fillView.bounds.width > 1 else {
      if fillView.layer.mask != nil {
        fillView.layer.mask = nil
      }
      lastKnockoutMaskKey = nil
      iconView.isHidden = false
      return
    }

    iconView.isHidden = true
    let size = fillView.bounds.size
    let glyphSize = glyph.size
    // The glyph's own size is part of the key, not decoration: the same symbol name is
    // set at different point sizes and weights, and two of those render different masks.
    let key =
      "\(currentIconName ?? "-")|\(Int(glyphSize.width))x\(Int(glyphSize.height))"
      + "|\(Int(size.width))x\(Int(size.height))"
    guard key != lastKnockoutMaskKey else { return }
    lastKnockoutMaskKey = key

    let maskImage: UIImage
    if let cached = Self.knockoutMaskCache.object(forKey: key as NSString) {
      maskImage = cached
    } else {
      let glyphRect = CGRect(
        x: (size.width - glyphSize.width) * 0.5,
        y: (size.height - glyphSize.height) * 0.5,
        width: glyphSize.width,
        height: glyphSize.height
      )
      maskImage = UIGraphicsImageRenderer(size: size).image { _ in
        UIColor.black.setFill()
        UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
        glyph.draw(in: glyphRect, blendMode: .destinationOut, alpha: 1.0)
      }
      Self.knockoutMaskCache.setObject(maskImage, forKey: key as NSString)
    }

    let maskLayer = CALayer()
    maskLayer.frame = fillView.bounds
    maskLayer.contents = maskImage.cgImage
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fillView.layer.mask = maskLayer
    CATransaction.commit()
  }

  private func setIcon(_ image: UIImage?, name: String) {
    iconView.image = image
    currentIconName = name
    iconView.tintColor = resolvedIconTintColor()
    refreshIconKnockout()
  }

  func setPlaybackState(isPlaying: Bool, progress: CGFloat, level: CGFloat = 0.0) {
    // The center glyph is always the play/pause control; download chrome now lives on
    // the corner badge, so playback state applies unconditionally — except while an
    // upload owns the center ring + cancel glyph.
    guard !isUploading else { return }
    applyPlaybackChrome(isPlaying: isPlaying, progress: progress, level: level)
  }

  private func applyPlaybackChrome(isPlaying: Bool, progress: CGFloat, level: CGFloat) {
    // Called once per display frame for as long as audio plays. Only the fluid level below
    // is genuinely per-frame; rebuilding the symbol image and re-assigning `iconView.image`
    // at 120Hz was pure waste, and it landed inside the scroll's frame budget.
    // `currentIconName` self-invalidates: any other path (upload, download, failure) that
    // swaps the glyph makes the guard fall through and the chrome re-apply.
    let symbol = isPlaying ? "pause.fill" : "play.fill"
    if currentIconName != symbol {
      ringProgressLayer.removeAnimation(forKey: uploadProgressAnimationKey)
      ringProgressLayer.removeAnimation(forKey: uploadSpinAnimationKey)
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      ringProgressLayer.transform = CATransform3DIdentity
      ringProgressLayer.strokeStart = 0.0
      ringProgressLayer.strokeEnd = 0.0 // Never show center ring for playback
      CATransaction.commit()
      let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
      setIcon(UIImage(systemName: symbol, withConfiguration: config), name: symbol)
    }

    // Classic fluid behind the plate — level from metering; color from applyStyle / cover.
    fluidVisualizer.level = level
    if isPlaying {
      if fluidVisualizer.alpha < 0.05 { fluidVisualizer.start() }
    } else {
      fluidVisualizer.stop()
    }
  }

  func setUploadState(isUploading: Bool, progress: CGFloat?) {
    if isUploading {
      needsDownload = false
      isDownloading = false
      downloadProgress = nil
      downloadFailed = false
      updateDownloadBadge()
    }
    let resolvedProgress: CGFloat?
    if isUploading {
      if let normalizedProgress = quantizedTransferProgress(
        progress, minimum: minimumUploadProgress)
      {
        lastResolvedUploadProgress = normalizedProgress
        resolvedProgress = normalizedProgress
      } else if let lastResolvedUploadProgress {
        resolvedProgress = lastResolvedUploadProgress
      } else {
        lastResolvedUploadProgress = minimumUploadProgress
        resolvedProgress = minimumUploadProgress
      }
    } else {
      resolvedProgress = nil
      lastResolvedUploadProgress = nil
    }
    if self.isUploading == isUploading, self.uploadProgress == resolvedProgress {
      return
    }
    self.isUploading = isUploading
    self.uploadProgress = resolvedProgress
    updateUploadRingVisual()
  }

  func setDownloadState(needsDownload: Bool, isDownloading: Bool, progress: CGFloat?) {
    guard !isUploading else { return }
    // Any live download push supersedes a latched failure badge.
    downloadFailed = false

    // Keep the badge/spinner latched for the whole transfer. Transient reconfigure
    // passes with isDownloading=false would blank the circle mid-download.
    let clampedProgress: CGFloat?
    if isDownloading {
      if let progress, progress.isFinite {
        let next = max(0.0, min(1.0, progress))
        // Monotonic — never snap the ring backward.
        if let prev = downloadProgress, next + 0.001 < prev {
          clampedProgress = prev
        } else {
          clampedProgress = next
        }
      } else {
        clampedProgress = downloadProgress  // keep last known
      }
    } else if !needsDownload {
      clampedProgress = nil
    } else {
      // Idle downloadable state (not transferring) — clear progress.
      clampedProgress = nil
    }

    // If we were downloading and a reconfigure claims "not downloading" while still
    // needing a download, ignore the false idle flicker (race with snapshot publish).
    if self.isDownloading && !isDownloading && needsDownload {
      updateDownloadBadge()
      return
    }

    self.needsDownload = needsDownload
    self.isDownloading = isDownloading
    self.downloadProgress = clampedProgress
    updateDownloadBadge()
  }

  /// Terminal failure: a broken source that can't be downloaded. The badge turns red —
  /// the spinner never lingers, and the center stays a plain play glyph.
  func setDownloadFailed() {
    guard !isUploading else { return }
    downloadFailed = true
    needsDownload = true
    isDownloading = false
    downloadProgress = nil
    updateDownloadBadge()
    applyPlaybackChrome(isPlaying: false, progress: 0.0, level: 0.0)
  }

  /// Drive the bottom-right corner badge: down-arrow (idle), a continuously spinning arc
  /// (downloading/buffering — a plain SPINNER, never a jumpy determinate ring that can reset
  /// to zero), or a red error mark (failed). Hidden when there is nothing to download.
  ///
  /// Colors: the badge fill is the appearance accent (passed via `applyStyle` → ringTintColor),
  /// the spinner arc is white, and failure turns the fill red. No border.
  private func updateDownloadBadge() {
    let show = downloadFailed || needsDownload || isDownloading
    downloadBadgeView.isHidden = !show
    guard show else {
      downloadBadgeRingLayer.removeAnimation(forKey: badgeSpinAnimationKey)
      downloadBadgeRingLayer.removeAnimation(forKey: badgeProgressAnimationKey)
      downloadBadgeRingLayer.strokeEnd = 0.0
      return
    }

    if downloadFailed {
      downloadBadgeView.backgroundColor = UIColor(red: 0.90, green: 0.23, blue: 0.20, alpha: 0.95)
      downloadBadgeRingLayer.removeAnimation(forKey: badgeSpinAnimationKey)
      downloadBadgeRingLayer.removeAnimation(forKey: badgeProgressAnimationKey)
      downloadBadgeRingLayer.strokeEnd = 0.0
      let config = UIImage.SymbolConfiguration(pointSize: 11, weight: .heavy)
      downloadBadgeIconView.image = UIImage(systemName: "exclamationmark", withConfiguration: config)
      return
    }

    // Accent fill (from appearance), white spinner arc.
    downloadBadgeView.backgroundColor = badgeTintColor
    downloadBadgeRingLayer.strokeColor = UIColor.white.cgColor

    guard isDownloading else {
      // Needs download, idle: a plain down-arrow, no ring.
      downloadBadgeRingLayer.removeAnimation(forKey: badgeSpinAnimationKey)
      downloadBadgeRingLayer.removeAnimation(forKey: badgeProgressAnimationKey)
      downloadBadgeRingLayer.strokeStart = 0.0
      downloadBadgeRingLayer.strokeEnd = 0.0
      let config = UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
      downloadBadgeIconView.image = UIImage(systemName: "arrow.down", withConfiguration: config)
      return
    }

    // Downloading / buffering: a continuously spinning quarter-arc — a plain SPINNER, no
    // byte progress (which jumped 5% then snapped back to zero on the old broken loop).
    downloadBadgeIconView.image = nil
    downloadBadgeRingLayer.removeAnimation(forKey: badgeProgressAnimationKey)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    downloadBadgeRingLayer.strokeStart = 0.0
    downloadBadgeRingLayer.strokeEnd = 0.28
    CATransaction.commit()
    if downloadBadgeRingLayer.animation(forKey: badgeSpinAnimationKey) == nil {
      let spin = CABasicAnimation(keyPath: "transform.rotation.z")
      spin.fromValue = 0.0
      spin.toValue = 2.0 * CGFloat.pi
      spin.duration = 1.0
      spin.repeatCount = .infinity
      spin.timingFunction = CAMediaTimingFunction(name: .linear)
      spin.isRemovedOnCompletion = false
      downloadBadgeRingLayer.add(spin, forKey: badgeSpinAnimationKey)
    }
  }

  /// Hard reset for cell reuse.
  func resetDownloadChromeForReuse() {
    downloadFailed = false
    needsDownload = false
    isDownloading = false
    downloadProgress = nil
    // Reuse is exactly when the style memo must not be trusted — the next row may want
    // the same colors but this cell's chrome has just been torn down underneath them.
    lastAppliedPlateStyle = nil
    updateDownloadBadge()
    applyPlaybackChrome(isPlaying: false, progress: 0.0, level: 0.0)
  }

  private func updateUploadRingVisual() {
    guard isUploading else {
      ringProgressLayer.removeAnimation(forKey: uploadProgressAnimationKey)
      ringProgressLayer.removeAnimation(forKey: uploadSpinAnimationKey)
      ringProgressLayer.strokeStart = 0.0
      ringProgressLayer.strokeEnd = 0.0
      return
    }
    let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
    setIcon(UIImage(systemName: "xmark", withConfiguration: config), name: "xmark")

    let targetProgress = max(minimumUploadProgress, min(1.0, uploadProgress ?? minimumUploadProgress))
    let currentProgress = ringProgressLayer.presentation()?.strokeEnd ?? ringProgressLayer.strokeEnd
    let shouldAnimate =
      abs(currentProgress - targetProgress) >= chatTransferProgressAnimationThreshold
      || targetProgress >= 0.999

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ringProgressLayer.strokeStart = 0.0
    ringProgressLayer.strokeEnd = targetProgress
    CATransaction.commit()

    if shouldAnimate {
      let progressAnimation = CABasicAnimation(keyPath: "strokeEnd")
      progressAnimation.fromValue = currentProgress
      progressAnimation.toValue = targetProgress
      progressAnimation.duration = 0.16
      progressAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
      ringProgressLayer.add(progressAnimation, forKey: uploadProgressAnimationKey)
    } else {
      ringProgressLayer.removeAnimation(forKey: uploadProgressAnimationKey)
    }

    if ringProgressLayer.animation(forKey: uploadSpinAnimationKey) == nil {
      let spin = CABasicAnimation(keyPath: "transform.rotation.z")
      spin.fromValue = 0.0
      spin.toValue = (2.0 * CGFloat.pi)
      spin.duration = 1.57
      spin.repeatCount = .infinity
      spin.timingFunction = CAMediaTimingFunction(name: .linear)
      spin.isRemovedOnCompletion = true
      ringProgressLayer.add(spin, forKey: uploadSpinAnimationKey)
    }
  }

  private func resolvedIconTintColor() -> UIColor {
    artworkImageView.image == nil ? iconTintColor : .white
  }

  /// Cheap dominant-color probe: average the image down to 1×1 and lift saturation so a
  /// muted mean still reads as a tint. Runs once per artwork set, off the hot path.
  static func dominantColor(of image: UIImage) -> UIColor? {
    guard let cg = image.cgImage else { return nil }
    var pixel = [UInt8](repeating: 0, count: 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard
      let ctx = CGContext(
        data: &pixel,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .medium
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let r = CGFloat(pixel[0]) / 255.0
    let g = CGFloat(pixel[1]) / 255.0
    let b = CGFloat(pixel[2]) / 255.0
    var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
    UIColor(red: r, green: g, blue: b, alpha: 1.0).getHue(
      &h, saturation: &s, brightness: &v, alpha: &a)
    return UIColor(
      hue: h,
      saturation: min(1.0, s * 1.4 + 0.08),
      brightness: max(0.55, min(1.0, v + 0.12)),
      alpha: 1.0)
  }
}

final class VoiceWaveformView: UIView {
  private var barCount = 40
  private var barLayers: [CALayer] = []
  private var barEnvelope: [CGFloat] = []
  private var rawSamples: [CGFloat]?
  private var playbackProgress: CGFloat = 0.0
  private var level: CGFloat = 0.0
  private var isPlaying = false
  private var activeColor = UIColor.white
  private var inactiveColor = UIColor(white: 1.0, alpha: 0.28)
  /// Per-frame write avoidance in `applyBarFrames` — bar geometry and per-bar fill.
  private var lastBarGeometryKey: String?
  private var lastBarFillFractions: [CGFloat] = []
  /// Samples arrived but have not been bucketed yet. See ``setWaveform(_:)``.
  private var needsEnvelopeRebuild = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let expectedBarWidth: CGFloat = 2.0
    let expectedSpacing: CGFloat = 2.0
    let newCount = max(1, Int(bounds.width / (expectedBarWidth + expectedSpacing)))
    if newCount != barCount || barLayers.isEmpty {
      barCount = newCount
      barLayers.forEach { $0.removeFromSuperlayer() }
      barLayers.removeAll()
      for _ in 0..<barCount {
        let layer = CALayer()
        layer.backgroundColor = inactiveColor.cgColor
        layer.cornerCurve = .continuous
        barLayers.append(layer)
        self.layer.addSublayer(layer)
      }
      rebuildEnvelope()
      needsEnvelopeRebuild = false
      invalidateBarCaches()
    } else if needsEnvelopeRebuild {
      // Same bar count, new audio: the samples ``setWaveform(_:)`` deferred to here.
      rebuildEnvelope()
      needsEnvelopeRebuild = false
      invalidateBarCaches()
    }
    applyBarFrames()
  }

  func applyColors(active: UIColor, inactive: UIColor) {
    guard active != activeColor || inactive != inactiveColor else { return }
    activeColor = active
    inactiveColor = inactive
    invalidateBarCaches()
    applyBarFrames()
  }

  func setWaveform(_ samples: [CGFloat]?) {
    rawSamples = samples
    // Resample at LAYOUT, not here — this is the wave that changes shape a beat after a
    // chat opens.
    //
    // The envelope is `rawSamples` bucketed into `barCount` buckets, and `barCount` is a
    // function of `bounds.width` that only ``layoutSubviews()`` knows. Cells are
    // configured *before* they are laid out, so on a recycled cell this ran while
    // `bounds` still described the PREVIOUS row: the new audio was bucketed into the old
    // bar count and painted (`barLayers` is already populated from that row, so
    // `applyBarFrames` does not early-return), and layout then re-bucketed it into the
    // right count a frame later. Two different shapes for one voice note.
    //
    // Deferring costs nothing: `setNeedsLayout` runs before this frame is displayed, so
    // the first shape drawn is the only shape drawn.
    needsEnvelopeRebuild = true
    setNeedsLayout()
  }

  private func rebuildEnvelope() {
    guard barCount > 0 else { return }
    guard let samples = rawSamples, !samples.isEmpty else {
      barEnvelope = Self.makeDefaultEnvelope(count: barCount)
      return
    }
    let normalized =
      samples
      .filter { $0.isFinite }
      .map { max(0.0, min(1.0, $0)) }
    guard !normalized.isEmpty else {
      barEnvelope = Self.makeDefaultEnvelope(count: barCount)
      return
    }

    var resampled = Array(repeating: CGFloat.zero, count: barCount)
    for index in 0..<normalized.count {
      let bucketIndex = min(barCount - 1, (index * barCount) / max(1, normalized.count))
      resampled[bucketIndex] = max(resampled[bucketIndex], normalized[index])
    }

    if let maxSample = resampled.max(), maxSample > 0.0001 {
      let inverseScale = 1.0 / maxSample
      resampled = resampled.map { max(0.0, min(1.0, $0 * inverseScale)) }
    } else {
      barEnvelope = Self.makeDefaultEnvelope(count: barCount)
      return
    }

    if resampled.allSatisfy({ $0 <= 0.001 }) {
      barEnvelope = Self.makeDefaultEnvelope(count: barCount)
      return
    }

    barEnvelope = resampled
  }

  func setPlayback(progress: CGFloat, level: CGFloat, isPlaying: Bool) {
    playbackProgress = max(0.0, min(1.0, progress))
    self.level = max(0.0, min(1.0, level))
    self.isPlaying = isPlaying
    applyBarFrames()
  }

  private func applyBarFrames() {
    guard !barLayers.isEmpty, bounds.width > 1.0, bounds.height > 1.0 else { return }
    let barWidth: CGFloat = 2.0
    let spacing: CGFloat = 2.0
    let minHeight: CGFloat = 2.0
    let peakHeight = max(minHeight, min(bounds.height, 18.0))
    let progressX = max(0.0, min(bounds.width, playbackProgress * bounds.width))
    var x: CGFloat = 0.0

    // Runs at the display refresh rate for the whole length of a voice note or track, so
    // it only touches what the playhead actually moved. Bar geometry is a function of the
    // envelope and the bounds — not of progress — so it is written once and then left
    // alone, and colours are only re-assigned for bars whose fill genuinely changed.
    let geometryKey = "\(Int(bounds.width))x\(Int(bounds.height))|\(barEnvelope.count)"
    let geometryChanged = geometryKey != lastBarGeometryKey
    if geometryChanged { lastBarGeometryKey = geometryKey }
    if lastBarFillFractions.count != barLayers.count {
      lastBarFillFractions = Array(repeating: -1.0, count: barLayers.count)
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (index, barLayer) in barLayers.enumerated() {
      let amplitude = max(0.0, min(1.0, barEnvelope[index]))
      let barHeight = max(minHeight, peakHeight * amplitude)
      let barStart = x
      let barEnd = x + barWidth

      if geometryChanged {
        let renderedHeight = max(1.0, floor(barHeight))
        let y = floor(bounds.height - renderedHeight)
        barLayer.frame = CGRect(x: x, y: y, width: barWidth, height: renderedHeight)
        barLayer.cornerRadius = barWidth * 0.5
      }

      let fillFraction = max(0.0, min(1.0, (progressX - barStart) / max(1.0, barEnd - barStart)))
      // A bar is fully ahead of or fully behind the playhead almost all the time; only the
      // one or two straddling it need a fresh blend.
      if geometryChanged || abs(fillFraction - lastBarFillFractions[index]) > 0.01 {
        lastBarFillFractions[index] = fillFraction
        barLayer.backgroundColor = blendedColor(fraction: fillFraction)
      }
      x += barWidth + spacing
    }
    CATransaction.commit()
  }

  /// Invalidates the geometry/colour caches in `applyBarFrames` when the thing they are
  /// keyed on is replaced wholesale (new colours, new samples, resize).
  private func invalidateBarCaches() {
    lastBarGeometryKey = nil
    lastBarFillFractions = []
  }

  private func blendedColor(fraction: CGFloat) -> CGColor {
    if fraction <= 0.0 { return inactiveColor.cgColor }
    if fraction >= 1.0 { return activeColor.cgColor }

    var ar: CGFloat = 0
    var ag: CGFloat = 0
    var ab: CGFloat = 0
    var aa: CGFloat = 0
    var ir: CGFloat = 0
    var ig: CGFloat = 0
    var ib: CGFloat = 0
    var ia: CGFloat = 0
    guard
      activeColor.getRed(&ar, green: &ag, blue: &ab, alpha: &aa),
      inactiveColor.getRed(&ir, green: &ig, blue: &ib, alpha: &ia)
    else {
      return activeColor.withAlphaComponent(fraction).cgColor
    }
    let t = fraction
    return UIColor(
      red: ir + ((ar - ir) * t),
      green: ig + ((ag - ig) * t),
      blue: ib + ((ab - ib) * t),
      alpha: ia + ((aa - ia) * t)
    ).cgColor
  }


  private static func makeDefaultEnvelope(count: Int) -> [CGFloat] {
    guard count > 0 else { return [] }
    let template: [CGFloat] = [0.64, 0.49, 0.73, 0.56, 0.42, 0.78, 0.58, 0.28, 0.33, 0.67]
    return (0..<count).map { index in
      template[index % template.count]
    }
  }
}

protocol VoicePlayableCell: AnyObject {
  func applyVoicePlaybackState(isPlaying: Bool, progress: CGFloat, level: CGFloat)
  func applyVoiceDownloadState(needsDownload: Bool, isDownloading: Bool, progress: CGFloat?)
  /// Terminal download failure — render inline "Couldn't load · Tap to retry" chrome.
  func applyVoiceDownloadFailedState()
}

fileprivate struct ChatAudioQueueItem {
  let chatId: String
  let messageId: String
  let mediaURL: String
  let mediaKey: String?
  let fileName: String?
  let title: String
  let subtitle: String
  let artwork: UIImage?
  let duration: Double
  let track: NativeMusicPlayerTrack
}

final class ChatAudioQueueRegistry {
  static let shared = ChatAudioQueueRegistry()

  private var itemsByChatId: [String: [ChatAudioQueueItem]] = [:]

  private init() {}

  func setRows(_ rows: [ChatListRow], for chatId: String) {
    let trimmedChatId = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedChatId.isEmpty else { return }

    var nextItems: [ChatAudioQueueItem] = []
    var seenMessageIds = Set<String>()
    var musicCandidates = 0
    nextItems.reserveCapacity(rows.count)

    for row in rows {
      if usesAudioMetadataVoiceLayout(row) { musicCandidates += 1 }
      guard let item = makeItem(from: row, fallbackChatId: trimmedChatId) else { continue }
      if seenMessageIds.insert(item.messageId).inserted {
        nextItems.append(item)
        _ = NativeMusicPlayerStore.shared.cacheTrack(payload: item.track.toPayload())
      }
    }

    itemsByChatId[trimmedChatId] = nextItems
    // The store is persistent + accumulates across windows, so the sheet list can exceed
    // what this window registered. If musicCandidates > registered, per-row [MusicList]
    // skip logs above say why (no id / no media URL).
    let persistedTotal = NativeMusicPlayerStore.shared.tracks(forChatId: trimmedChatId).count
    NSLog(
      "[MusicList] setRows chat=%@ rows=%d musicCandidates=%d registered=%d persistedTotal=%d",
      trimmedChatId,
      rows.count,
      musicCandidates,
      nextItems.count,
      persistedTotal
    )
  }

  func tracks(for chatId: String?) -> [NativeMusicPlayerTrack] {
    items(for: chatId).map(\.track)
  }

  /// Register ONE music row into the persistent store + per-chat queue immediately, keyed on
  /// `chatId`. Independent of the batch `setRows` path — that runs off the row-diff/apply pass,
  /// which the cold-open cache/snapshot paint can skip (and per-message payloads often omit
  /// `chat_id`, so `row.chatId` is nil). Called at music-cell configure so EVERY rendered track
  /// lands in the chat's player-sheet list, not just the tapped one.
  func registerMusicRow(_ row: ChatListRow, chatId: String) {
    let trimmed = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard let item = makeItem(from: row, fallbackChatId: trimmed) else { return }
    let key = item.chatId
    var chatItems = itemsByChatId[key] ?? []
    // Only touch the store on a genuinely new track — cacheTrack is a JSON encode +
    // UserDefaults write, and this runs on every music-cell configure.
    guard !chatItems.contains(where: { $0.messageId == item.messageId }) else { return }
    chatItems.append(item)
    itemsByChatId[key] = chatItems
    _ = NativeMusicPlayerStore.shared.cacheTrack(payload: item.track.toPayload())
    NSLog(
      "[MusicList] registerMusicRow chat=%@ msg=%@ chatTotal=%d",
      key,
      item.messageId,
      chatItems.count
    )
  }

  func tracks(for chatId: String?, fallbackTrackId: String?) -> [NativeMusicPlayerTrack] {
    if let fallbackTrackId,
      let resolvedChatId = resolvedChatId(for: fallbackTrackId, preferredChatId: chatId)
    {
      return items(for: resolvedChatId).map(\.track)
    }
    return tracks(for: chatId)
  }

  func artwork(for trackId: String, in chatId: String?) -> UIImage? {
    item(trackId: trackId, in: chatId)?.artwork
      ?? resolvedItem(trackId: trackId, preferredChatId: chatId)?.artwork
  }

  fileprivate func items(for chatId: String?) -> [ChatAudioQueueItem] {
    let trimmedChatId = chatId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmedChatId.isEmpty else { return [] }
    return itemsByChatId[trimmedChatId] ?? []
  }

  fileprivate func item(trackId: String, in chatId: String?) -> ChatAudioQueueItem? {
    items(for: chatId).first { $0.track.trackId == trackId }
  }

  fileprivate func resolvedItem(trackId: String, preferredChatId: String?) -> ChatAudioQueueItem? {
    if let item = item(trackId: trackId, in: preferredChatId) {
      return item
    }
    guard let resolvedChatId = resolvedChatId(for: trackId, preferredChatId: preferredChatId) else {
      return nil
    }
    return item(trackId: trackId, in: resolvedChatId)
  }


  fileprivate func resolvedChatId(for trackId: String, preferredChatId: String?) -> String? {
    let trimmedTrackId = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTrackId.isEmpty else { return nil }

    let trimmedPreferredChatId = preferredChatId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmedPreferredChatId.isEmpty,
      itemsByChatId[trimmedPreferredChatId]?.contains(where: {
        $0.messageId == trimmedTrackId || $0.track.trackId == trimmedTrackId
      }) == true
    {
      return trimmedPreferredChatId
    }

    for (chatId, chatItems) in itemsByChatId {
      if chatItems.contains(where: {
        $0.messageId == trimmedTrackId || $0.track.trackId == trimmedTrackId
      }) {
        return chatId
      }
    }
    return nil
  }

  private func makeItem(from row: ChatListRow, fallbackChatId: String) -> ChatAudioQueueItem? {
    guard usesAudioMetadataVoiceLayout(row) else { return nil }
    guard let messageId = normalizedChatAudioId(row.messageId) else {
      NSLog(
        "[MusicList] skip music row — no messageId · type=%@ hasCover=%@ file=%@",
        row.messageType,
        (row.musicCoverURL?.isEmpty == false) ? "Y" : "N",
        row.fileName ?? "-"
      )
      return nil
    }

    // Same rule as the bubble: a recorded local path counts only while the file exists.
    // A queue item built on a dead path can never play and never falls back to the vault.
    let localMedia = chatExistingLocalMediaPath(row.localMediaUrl)
    let remoteMedia = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedMediaURL: String?
    if let localMedia, !localMedia.isEmpty {
      resolvedMediaURL = localMedia
    } else if let remoteMedia, !remoteMedia.isEmpty {
      resolvedMediaURL = remoteMedia
    } else {
      resolvedMediaURL = nil
    }
    guard let mediaURL = resolvedMediaURL else {
      // Real music (has cover/artist/source) but no playable URL on the row → can't be
      // added to the queue/list. Logged so we can see exactly which tracks fall out and why.
      NSLog(
        "[MusicList] skip music msgId=%@ — no media URL · type=%@ hasCover=%@ source=%@ title=%@",
        messageId,
        row.messageType,
        (row.musicCoverURL?.isEmpty == false) ? "Y" : "N",
        row.musicSource ?? "-",
        resolvedAudioVoiceTitle(row)
      )
      return nil
    }

    let title = resolvedAudioVoiceTitle(row)
    let subtitle = resolvedAudioVoiceStaticDetail(row)
    let artwork = chatMusicArtworkImage(for: row)
    let duration = max(0.0, row.duration ?? 0.0)
    let localURI = localMedia?.isEmpty == false ? localMedia : nil
    let remoteURI: String? = {
      guard let remoteMedia, !remoteMedia.isEmpty else { return nil }
      guard !(remoteMedia.hasPrefix("file://") || remoteMedia.hasPrefix("/")) else { return nil }
      return remoteMedia
    }()
    let resolvedChatId = normalizedChatAudioId(row.chatId) ?? fallbackChatId
    let track = NativeMusicPlayerTrack(
      trackId: messageId,
      videoId: nil,
      id: messageId,
      source: "chat-music",
      title: title,
      artist: subtitle,
      album: nil,
      duration: formatBubbleDuration(seconds: duration),
      durationSeconds: duration > 0.0 ? duration : nil,
      cover: row.musicCoverURL?.trimmingCharacters(in: .whitespacesAndNewlines),
      previewURL: remoteURI,
      streamURL: remoteURI,
      localURI: localURI,
      cachedAt: nil,
      playCount: 0,
      lastPlayedAt: nil,
      links: ["chat_id": resolvedChatId]
    )
    return ChatAudioQueueItem(
      chatId: resolvedChatId,
      messageId: messageId,
      mediaURL: mediaURL,
      mediaKey: row.mediaKey,
      fileName: row.fileName,
      title: title,
      subtitle: subtitle,
      artwork: artwork,
      duration: duration,
      track: track
    )
  }
}

struct VoiceBubblePlaybackSnapshot {
  let messageId: String?
  let chatId: String?
  let isPlaying: Bool
  let progress: CGFloat
  let duration: Double
  let playbackRate: Double
  let queueOrderMode: NativeMusicPlayerQueueOrderMode
  let isRepeatEnabled: Bool
  let isDownloading: Bool
  let downloadProgress: CGFloat?
  /// 0.0…1.0 while downloading with a known total; nil when indeterminate or not downloading.
  let downloadFraction: CGFloat?
  /// Bytes written so far; nil when not downloading.
  let downloadedBytes: Int64?
  /// Expected total bytes; nil when the server sent no Content-Length.
  let totalBytes: Int64?
  let title: String?
  let subtitle: String?
  let artwork: UIImage?
  let presentsGlobalPlayer: Bool

  static let empty = VoiceBubblePlaybackSnapshot(
    messageId: nil,
    chatId: nil,
    isPlaying: false,
    progress: 0.0,
    duration: 0.0,
    playbackRate: 1.0,
    queueOrderMode: .forward,
    isRepeatEnabled: false,
    isDownloading: false,
    downloadProgress: nil,
    downloadFraction: nil,
    downloadedBytes: nil,
    totalBytes: nil,
    title: nil,
    subtitle: nil,
    artwork: nil,
    presentsGlobalPlayer: false
  )
}

extension Notification.Name {
  static let voiceBubblePlaybackDidChange = Notification.Name(
    "ChatNative.voiceBubblePlaybackDidChange")
}

final class VoiceBubblePlaybackCoordinator: NSObject, AVAudioPlayerDelegate {
  static let shared = VoiceBubblePlaybackCoordinator()

  private weak var activeCell: VoicePlayableCell?
  private var activeMessageId: String?
  private var activeChatId: String?
  private var activeMediaURL: String?
  private var player: AVAudioPlayer?
  private var streamingPlayer: AVPlayer?
  private var streamingPlayerStatusObservation: NSKeyValueObservation?
  private var streamingTimeObserver: Any?
  private var streamingEndObserver: NSObjectProtocol?
  private var displayLink: CADisplayLink?
  private var playbackProgress: CGFloat = 0.0
  private var level: CGFloat = 0.0
  private var isPlaying = false
  private var playbackRate: Double = 1.0
  private var queueOrderMode: NativeMusicPlayerQueueOrderMode = .forward
  private var isRepeatEnabled = false
  private var activeDownloadTask: URLSessionDownloadTask?
  private var activeDownloadProgressObservation: NSKeyValueObservation?
  private var activeDownloadProgress: CGFloat?
  private var activeDownloadedBytes: Int64?
  private var activeTotalBytes: Int64?
  private var lastDownloadProgressPublishTime: CFTimeInterval = 0
  /// Quiet background download of the *next* queue track (does not drive the active ring/UI).
  private var prefetchDownloadTask: URLSessionDownloadTask?
  private var prefetchMessageId: String?
  private var activeMediaKey: String?
  private var activeFileName: String?
  /// Messages we've already re-fetched once after evicting a poisoned voice cache
  /// (a non-audio body written as ".m4a"). Bounds the self-heal retry to one round so
  /// a genuinely broken source can't loop.
  private var poisonedCacheRetriedMessageIds: Set<String> = []
  /// The track's own remote source, kept alongside `activeMediaURL`. A persisted
  /// `localURI` is only a *hint* — the container UUID changes on every install and
  /// Caches is purged — so when the local file is missing or won't decode, this is
  /// what the tap falls back to instead of dying.
  private var activeRemoteFallbackURL: String?
  /// When the current `beginPlayback` started, so the tap→banner latency is visible in
  /// the log rather than guessed at.
  private var playbackRequestedAt: CFTimeInterval = 0.0
  private var activeTitle: String?
  private var activeSubtitle: String?
  private var activeArtwork: UIImage?
  private var activeDuration: Double = 0.0
  private var presentsGlobalPlayer = false
  /// The global mini-player banner stays suppressed until audio actually starts
  /// (first successful play / stream ready). A tap that is still downloading — or a
  /// broken source that never plays — therefore never flashes the banner. Latches on
  /// the first `isPlaying`; reset when playback is torn down or a new item begins.
  private var bannerPlaybackStarted = false
  private var shouldResumeAfterInterruption = false
  private var didConfigureRemoteCommands = false
  /// Latches for the two mediaserverd round trips in `configurePlaybackSession`.
  private var didConfigurePlaybackCategory = false
  private var didActivateAudioSession = false
  private var audioSessionEpoch = 0
  private var lastNowPlayingSignature: String?
  /// Snapshot fan-out throttle — see `publishSnapshot`.
  private var lastPublishedSemanticSignature: String?
  private var lastSnapshotPublishAt: Double = 0
  /// Remote-command enablement last pushed to MediaRemote, so the five setters below are
  /// not re-run on every playback tick.
  private var lastRemoteCommandSignature: String?
  private var randomizedQueueMessageIds: [String] = []
  /// Manual drag-to-reorder override per chat (ordered trackIds == messageIds). When set
  /// for the active chat, it defines the base play order the player sheet's "Next Up" list
  /// was dragged into; forward mode honors it, reverse/random still transform on top.
  private var manualQueueOrderByChatId: [String: [String]] = [:]
  private(set) var currentSnapshot = VoiceBubblePlaybackSnapshot.empty

  /// Set an explicit queue order for the active chat (drag-to-reorder from the player
  /// sheet). `orderedTrackIds` are trackIds (== messageIds) in the desired play order.
  func setManualQueueOrder(_ orderedTrackIds: [String]) {
    guard let chatId = activeChatId else { return }
    manualQueueOrderByChatId[chatId] = orderedTrackIds
    syncRandomizedQueueMessageIds(anchorMessageId: activeMessageId, regenerate: true)
    publishSnapshot()
  }

  /// Live download byte counts for the active bubble (nil when no download is in flight).
  var activeDownloadByteCounts: (downloaded: Int64?, total: Int64?) {
    guard activeDownloadTask != nil else { return (nil, nil) }
    return (activeDownloadedBytes, activeTotalBytes)
  }

  private override init() {
    super.init()
    configureSystemPlaybackIntegration()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    clearNowPlayingInfo()
    if Thread.isMainThread {
      UIApplication.shared.endReceivingRemoteControlEvents()
    } else {
      DispatchQueue.main.async {
        UIApplication.shared.endReceivingRemoteControlEvents()
      }
    }
    displayLink?.invalidate()
    player?.stop()
    cleanupStreamingPlayer()
  }

  private func configureSystemPlaybackIntegration() {
    // IMPORTANT: do NOT touch the MediaPlayer remote-command center here. The first
    // access to MPRemoteCommandCenter cold-starts the MediaPlayer framework, which
    // blocks the main thread ~2s (an os_log lock inside _CFXNotificationPost). This
    // coordinator is lazily created the moment ANY ChatListView is built — it scopes a
    // `.voiceBubblePlaybackDidChange` observer — so wiring remote commands in init froze
    // chat-open (the 2.2s `main-thread-stall` on `openChat`). The lock-screen / control-
    // center transport is only meaningful once audio actually plays, so it's configured
    // lazily on the first playback (configurePlaybackSession → configureRemoteCommandsIfNeeded).
    // Only the cheap, MediaPlayer-free observers stay here.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance()
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionRouteChange(_:)),
      name: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance()
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleApplicationDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleApplicationWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
  }

  private func configureRemoteCommandsIfNeeded() {
    guard !didConfigureRemoteCommands else { return }
    didConfigureRemoteCommands = true

    let commandCenter = MPRemoteCommandCenter.shared()
    commandCenter.playCommand.addTarget { [weak self] _ in
      self?.handleRemoteCommandOnMain {
        self?.handleRemotePlayCommand() ?? .commandFailed
      } ?? .commandFailed
    }
    commandCenter.pauseCommand.addTarget { [weak self] _ in
      self?.handleRemoteCommandOnMain {
        self?.handleRemotePauseCommand() ?? .commandFailed
      } ?? .commandFailed
    }
    commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.handleRemoteCommandOnMain {
        self?.handleRemoteTogglePlayPauseCommand() ?? .commandFailed
      } ?? .commandFailed
    }
    commandCenter.stopCommand.addTarget { [weak self] _ in
      self?.handleRemoteCommandOnMain {
        self?.handleRemoteStopCommand() ?? .commandFailed
      } ?? .commandFailed
    }
    commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      return self?.handleRemoteCommandOnMain {
        self?.handleRemoteChangePlaybackPositionCommand(event) ?? .commandFailed
      } ?? .commandFailed
    }
    commandCenter.nextTrackCommand.isEnabled = false
    commandCenter.previousTrackCommand.isEnabled = false
    commandCenter.seekForwardCommand.isEnabled = false
    commandCenter.seekBackwardCommand.isEnabled = false
    commandCenter.skipForwardCommand.isEnabled = false
    commandCenter.skipBackwardCommand.isEnabled = false
    syncRemoteCommandAvailability()
    // Begin receiving lock-screen / control-center remote events now that the command
    // targets exist (moved out of init with the rest of the MediaPlayer setup so the
    // cold-start cost is paid on first playback, not on chat-open).
    DispatchQueue.main.async {
      UIApplication.shared.beginReceivingRemoteControlEvents()
    }
  }

  private func handleRemoteCommandOnMain(
    _ action: @escaping () -> MPRemoteCommandHandlerStatus
  ) -> MPRemoteCommandHandlerStatus {
    if Thread.isMainThread {
      return action()
    }
    var status: MPRemoteCommandHandlerStatus = .commandFailed
    DispatchQueue.main.sync {
      status = action()
    }
    return status
  }

  private func configurePlaybackSession() throws {
    // First real playback: lazily wire the lock-screen / control-center transport.
    // Kept out of the coordinator's init so the MediaPlayer cold-start never stalls
    // chat-open (it's idempotent — guarded by `didConfigureRemoteCommands`).
    configureRemoteCommandsIfNeeded()
    let session = AVAudioSession.sharedInstance()
    // Both of these are synchronous round trips to mediaserverd on the main thread.
    // Re-running them for a track that starts while the session is already live and
    // already `.playback` buys nothing, so track→track switching now pays zero
    // session cost. The flags are cleared wherever the session is actually torn down.
    if !didConfigurePlaybackCategory {
      do {
        // Keep voice/audio-file playback aligned with the native global player engine.
        // The broader option set was intermittently failing on cached remote MP3 playback.
        try session.setCategory(.playback, mode: .default)
        didConfigurePlaybackCategory = true
      } catch {
        NSLog(
          "[ChatListView] voice audio session category failed error=%@",
          String(describing: error)
        )
        throw error
      }
    }
    if !didActivateAudioSession {
      do {
        audioSessionEpoch += 1
        try session.setActive(true)
        didActivateAudioSession = true
      } catch {
        NSLog(
          "[ChatListView] voice audio session activation failed error=%@",
          String(describing: error)
        )
        throw error
      }
    }
  }

  private var hasActivePlaybackEngine: Bool {
    player != nil || streamingPlayer != nil
  }

  private func currentPlaybackDuration() -> Double {
    if let player {
      return max(player.duration, activeDuration)
    }
    if let seconds = streamingPlayer?.currentItem?.duration.seconds,
      seconds.isFinite,
      seconds > 0.0
    {
      return max(seconds, activeDuration)
    }
    return activeDuration
  }

  private func currentPlaybackTime() -> Double {
    if let player {
      return max(0.0, min(player.currentTime, currentPlaybackDuration()))
    }
    if let seconds = streamingPlayer?.currentTime().seconds,
      seconds.isFinite,
      seconds >= 0.0
    {
      return max(0.0, min(seconds, currentPlaybackDuration()))
    }
    return max(0.0, min(Double(playbackProgress) * currentPlaybackDuration(), currentPlaybackDuration()))
  }

  private func isPlaybackCurrentlyPlaying() -> Bool {
    if let player {
      return player.isPlaying
    }
    if let streamingPlayer {
      return streamingPlayer.timeControlStatus == .playing
    }
    return false
  }

  private func syncRemoteCommandAvailability() {
    let hasPlayer = hasActivePlaybackEngine
    let canSeek = hasPlayer && currentPlaybackDuration() > 0.0
    // Reached on every playback tick. Each setter crosses into MediaRemote, so only push
    // when the enablement actually differs from what the system already has.
    let signature = [
      hasPlayer ? "1" : "0",
      isPlaying ? "1" : "0",
      canSeek ? "1" : "0",
      activeDownloadTask != nil ? "1" : "0",
    ].joined()
    guard signature != lastRemoteCommandSignature else { return }
    lastRemoteCommandSignature = signature

    let commandCenter = MPRemoteCommandCenter.shared()
    commandCenter.togglePlayPauseCommand.isEnabled = hasPlayer
    commandCenter.playCommand.isEnabled = hasPlayer && !isPlaying
    commandCenter.pauseCommand.isEnabled = hasPlayer && isPlaying
    commandCenter.stopCommand.isEnabled = hasPlayer || activeDownloadTask != nil
    commandCenter.changePlaybackPositionCommand.isEnabled = canSeek
  }

  private func resolvedSystemPlaybackTitle() -> String {
    if let activeTitle {
      let trimmed = activeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return trimmed
      }
    }
    if let activeFileName {
      let trimmed = activeFileName.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        let sanitizedTitle = (trimmed as NSString).lastPathComponent
        let displayTitle = (sanitizedTitle as NSString).deletingPathExtension
        return displayTitle.isEmpty ? sanitizedTitle : displayTitle
      }
    }
    return presentsGlobalPlayer ? "Audio" : "Voice message"
  }

  private func resolvedSystemPlaybackSubtitle() -> String? {
    if activeDownloadTask != nil {
      let progress = max(0.0, min(1.0, activeDownloadProgress ?? 0.0))
      let percent = Int((progress * 100.0).rounded())
      return percent > 0 ? "Downloading \(percent)%" : "Downloading"
    }
    if let activeSubtitle {
      let trimmed = activeSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return trimmed
      }
    }
    return "Vibegram"
  }

  private func updateNowPlayingInfo(force: Bool = false) {
    guard hasActivePlaybackEngine, activeMessageId != nil else {
      clearNowPlayingInfo()
      return
    }

    let title = resolvedSystemPlaybackTitle()
    let subtitle = resolvedSystemPlaybackSubtitle()
    let duration = currentPlaybackDuration()
    let elapsed = currentPlaybackTime()
    let signature = [
      activeMessageId ?? "-",
      title,
      subtitle ?? "",
      String(Int((elapsed * 2.0).rounded())),
      String(Int((duration * 2.0).rounded())),
      isPlaying ? "1" : "0",
    ].joined(separator: "|")

    if !force && signature == lastNowPlayingSignature {
      return
    }

    var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    nowPlayingInfo[MPMediaItemPropertyTitle] = title
    if let subtitle, !subtitle.isEmpty {
      nowPlayingInfo[MPMediaItemPropertyArtist] = subtitle
    } else {
      nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtist)
    }
    if duration > 0.0 {
      nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
    } else {
      nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
    }
    if let activeArtwork {
      nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
        boundsSize: activeArtwork.size
      ) { _ in
        activeArtwork
      }
    } else {
      nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtwork)
    }
    nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
    nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
    nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue

    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    if #available(iOS 13.0, *) {
      MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
    lastNowPlayingSignature = signature
  }

  private func clearNowPlayingInfo() {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    if #available(iOS 13.0, *) {
      MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
    lastNowPlayingSignature = nil
  }

  private func syncSystemPlaybackState(forceNowPlaying: Bool) {
    syncRemoteCommandAvailability()
    if !hasActivePlaybackEngine {
      clearNowPlayingInfo()
      return
    }
    updateNowPlayingInfo(force: forceNowPlaying)
  }

  @discardableResult
  private func resumePlayback(updateCell: Bool = true) -> Bool {
    do {
      try configurePlaybackSession()
    } catch {
      NSLog(
        "[ChatListView] voice resume failed to activate audio session error=%@",
        String(describing: error)
      )
    }
    let accepted: Bool
    if let player {
      accepted = player.play()
      player.rate = Float(playbackRate)
    } else if let streamingPlayer {
      streamingPlayer.playImmediately(atRate: Float(playbackRate))
      accepted = true
    } else {
      return false
    }
    isPlaying = accepted
    ensureDisplayLink()
    if updateCell {
      let isLoading = isMediaTransferActive(for: activeMessageId)
      pushDownloadState(
        to: activeCell,
        needsDownload: isLoading,
        isDownloading: isLoading
      )
      activeCell?.applyVoicePlaybackState(
        isPlaying: accepted,
        progress: playbackProgress,
        level: accepted ? max(level, 0.18) : 0.0
      )
    }
    publishSnapshot(forceNowPlaying: true)
    return accepted
  }

  private func pausePlayback(updateCell: Bool = true) {
    guard hasActivePlaybackEngine else { return }
    player?.pause()
    streamingPlayer?.pause()
    isPlaying = false
    level = 0.0
    if updateCell {
      let isLoading = isMediaTransferActive(for: activeMessageId)
      pushDownloadState(
        to: activeCell,
        needsDownload: isLoading,
        isDownloading: isLoading
      )
      activeCell?.applyVoicePlaybackState(
        isPlaying: false,
        progress: playbackProgress,
        level: 0.0
      )
    }
    publishSnapshot(forceNowPlaying: true)
  }

  private func handleRemotePlayCommand() -> MPRemoteCommandHandlerStatus {
    guard hasActivePlaybackEngine else { return .noActionableNowPlayingItem }
    return resumePlayback(updateCell: true) ? .success : .commandFailed
  }

  private func handleRemotePauseCommand() -> MPRemoteCommandHandlerStatus {
    guard hasActivePlaybackEngine else { return .noActionableNowPlayingItem }
    pausePlayback(updateCell: true)
    return .success
  }

  private func handleRemoteTogglePlayPauseCommand() -> MPRemoteCommandHandlerStatus {
    guard hasActivePlaybackEngine else { return .noActionableNowPlayingItem }
    if isPlaybackCurrentlyPlaying() {
      pausePlayback(updateCell: true)
      return .success
    }
    return resumePlayback(updateCell: true) ? .success : .commandFailed
  }

  private func handleRemoteStopCommand() -> MPRemoteCommandHandlerStatus {
    guard hasActivePlaybackEngine || activeDownloadTask != nil else { return .noActionableNowPlayingItem }
    stopActivePlayback(resetProgress: true)
    return .success
  }

  private func handleRemoteChangePlaybackPositionCommand(
    _ event: MPChangePlaybackPositionCommandEvent
  ) -> MPRemoteCommandHandlerStatus {
    guard hasActivePlaybackEngine else { return .noActionableNowPlayingItem }
    let duration = currentPlaybackDuration()
    let targetTime = max(0.0, min(duration > 0.0 ? duration : event.positionTime, event.positionTime))
    if let player {
      player.currentTime = targetTime
      playbackProgress = duration > 0.0 ? CGFloat(targetTime / duration) : 0.0
      activeCell?.applyVoicePlaybackState(
        isPlaying: player.isPlaying,
        progress: playbackProgress,
        level: player.isPlaying ? max(level, 0.18) : 0.0
      )
    } else if let streamingPlayer {
      let cmTime = CMTime(seconds: targetTime, preferredTimescale: 600)
      streamingPlayer.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
      playbackProgress = duration > 0.0 ? CGFloat(targetTime / duration) : 0.0
      activeCell?.applyVoicePlaybackState(
        isPlaying: streamingPlayer.timeControlStatus == .playing,
        progress: playbackProgress,
        level: streamingPlayer.timeControlStatus == .playing ? max(level, 0.18) : 0.0
      )
    }
    publishSnapshot(forceNowPlaying: true)
    return .success
  }

  @objc private func handleAudioSessionInterruption(_ notification: Notification) {
    guard
      let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
    else {
      return
    }

    switch type {
    case .began:
      // The system deactivates our session for us here, so the latch must drop or the
      // next start would skip reactivation and silently fail to play.
      didActivateAudioSession = false
      shouldResumeAfterInterruption = isPlaybackCurrentlyPlaying()
      if shouldResumeAfterInterruption {
        pausePlayback(updateCell: true)
      } else {
        publishSnapshot(forceNowPlaying: true)
      }
    case .ended:
      let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
      if shouldResumeAfterInterruption && options.contains(.shouldResume) {
        _ = resumePlayback(updateCell: true)
      } else {
        publishSnapshot(forceNowPlaying: true)
      }
      shouldResumeAfterInterruption = false
    @unknown default:
      break
    }
  }

  @objc private func handleAudioSessionRouteChange(_ notification: Notification) {
    guard
      let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
    else {
      return
    }

    if reason == .oldDeviceUnavailable, isPlaybackCurrentlyPlaying() {
      pausePlayback(updateCell: true)
    }
  }

  @objc private func handleApplicationDidEnterBackground() {
    publishSnapshot(forceNowPlaying: true)
  }

  @objc private func handleApplicationWillEnterForeground() {
    publishSnapshot(forceNowPlaying: true)
  }

  func bind(
    cell: VoicePlayableCell,
    messageId: String?,
    mediaURL: String?,
    mediaKey: String? = nil,
    fileName: String? = nil
  ) {
    guard let messageId, !messageId.isEmpty else {
      pushDownloadState(to: cell, needsDownload: false, isDownloading: false)
      cell.applyVoicePlaybackState(isPlaying: false, progress: 0.0, level: 0.0)
      return
    }
    if activeMessageId == messageId {
      activeCell = cell
      // Resolving / downloading must keep the badge spinning across cell rebinds.
      let isLoading = isMediaTransferActive(for: messageId)
      pushDownloadState(
        to: cell,
        needsDownload: isLoading || mediaURLRequiresDownload(mediaURL, mediaKey: mediaKey, fileName: fileName),
        isDownloading: isLoading
      )
      cell.applyVoicePlaybackState(
        isPlaying: isPlaying,
        progress: playbackProgress,
        level: level
      )
      return
    }
    if failedMessageIds.contains(messageId) {
      applyIdleState(
        cell: cell,
        messageId: messageId,
        mediaURL: mediaURL,
        mediaKey: mediaKey,
        fileName: fileName
      )
      cell.applyVoiceDownloadFailedState()
      return
    }
    applyIdleState(
      cell: cell,
      messageId: messageId,
      mediaURL: mediaURL,
      mediaKey: mediaKey,
      fileName: fileName
    )
  }

  private func applyIdleState(
    cell: VoicePlayableCell,
    messageId: String?,
    mediaURL: String?,
    mediaKey: String? = nil,
    fileName: String? = nil
  ) {
    let needsDownload =
      (messageId?.isEmpty == false)
      && mediaURLRequiresDownload(mediaURL, mediaKey: mediaKey, fileName: fileName)
    pushDownloadState(to: cell, needsDownload: needsDownload, isDownloading: false)
    cell.applyVoicePlaybackState(isPlaying: false, progress: 0.0, level: 0.0)
  }

  /// Push ring state. Live byte counts live on `currentSnapshot` for size captions + the sheet.
  private func pushDownloadState(
    to cell: VoicePlayableCell?,
    needsDownload: Bool,
    isDownloading: Bool
  ) {
    cell?.applyVoiceDownloadState(
      needsDownload: needsDownload,
      isDownloading: isDownloading,
      progress: isDownloading ? activeDownloadProgress : nil
    )
  }

  /// Read real byte counts from `URLSessionTask.progress` for the ring + snapshot.
  private func ingestDownloadProgress(from progress: Progress) {
    let completed = progress.completedUnitCount
    let total = progress.totalUnitCount
    if total > 0 {
      activeDownloadProgress = max(0.0, min(1.0, CGFloat(Double(completed) / Double(total))))
      activeDownloadedBytes = completed
      activeTotalBytes = total
    } else {
      // No Content-Length → indeterminate ring; still track completed when the task reports it.
      activeDownloadProgress = nil
      activeDownloadedBytes = completed > 0 ? completed : nil
      activeTotalBytes = nil
    }
  }

  private func clearActiveDownloadByteState() {
    activeDownloadProgress = nil
    activeDownloadedBytes = nil
    activeTotalBytes = nil
    lastDownloadProgressPublishTime = 0
  }

  /// Throttle UI/snapshot publishes to ~60 fps or ≥1% fraction change.
  private func shouldPublishDownloadProgressUpdate(previousFraction: CGFloat?) -> Bool {
    let now = CACurrentMediaTime()
    let elapsed = now - lastDownloadProgressPublishTime
    let fraction = activeDownloadProgress
    let previous = previousFraction
    let fractionDelta: CGFloat = {
      switch (previous, fraction) {
      case let (p?, f?):
        return abs(p - f)
      case (nil, .some), (.some, nil):
        return 1.0
      default:
        return 0.0
      }
    }()
    if fractionDelta >= 0.01 || fraction == 1.0 || elapsed >= (1.0 / 60.0) || lastDownloadProgressPublishTime == 0 {
      lastDownloadProgressPublishTime = now
      return true
    }
    return false
  }

  func unbind(cell: VoicePlayableCell) {
    if activeCell === cell {
      activeCell = nil
    }
  }

  // Terminal download failures latched per message so cells render an inline
  // "Couldn't load · Tap to retry" state instead of silently resetting to idle.
  private var failedMessageIds: Set<String> = []
  /// How many terminal failures we have seen for a message (reset on successful play).
  private var failedAttemptCounts: [String: Int] = [:]
  // Message currently resolving its backend stream URL (pre-download window) so
  // taps cancel instead of restarting and cell rebinds keep the loading chrome.
  private var resolvingMessageId: String?
  /// When the current resolve started. First play of a SoundCloud track makes the server
  /// download + re-host the audio (~5–10s), so taps in that window must NOT cancel the
  /// resolve (the user re-tapping impatiently used to kill it every time); only allow a
  /// cancel once it's clearly stuck.
  private var resolvingStartedAt: CFTimeInterval = 0
  private let resolveCancelGraceSeconds: CFTimeInterval = 15.0

  func isDownloadFailed(messageId: String?) -> Bool {
    guard let messageId, !messageId.isEmpty else { return false }
    return failedMessageIds.contains(messageId)
  }

  /// A broken source no longer retries on tap (that just looped a doomed download),
  /// so the copy points at re-sending instead of "Tap to retry". Repeated terminal
  /// failures escalate to a plainly-unavailable line.
  func voiceFailureCaption(for messageId: String?) -> String {
    let attempts = messageId.flatMap { failedAttemptCounts[$0] } ?? 1
    if attempts >= 2 {
      return "Track unavailable · Ask to resend"
    }
    return "Couldn't download · Ask to resend"
  }

  private func markDownloadFailed(messageId: String) {
    let next = (failedAttemptCounts[messageId] ?? 0) + 1
    failedAttemptCounts[messageId] = next
    NSLog(
      "[ChatListView] voice download terminal-failure messageId=%@ attempt=%d",
      messageId,
      next
    )
    failedMessageIds.insert(messageId)
    let cell = activeCell
    stopActivePlayback(resetProgress: true)
    cell?.applyVoiceDownloadFailedState()
  }

  func toggle(
    cell: VoicePlayableCell?,
    messageId: String?,
    chatId: String? = nil,
    mediaURL: String?,
    mediaKey: String? = nil,
    fileName: String? = nil,
    title: String? = nil,
    subtitle: String? = nil,
    artwork: UIImage? = nil,
    duration: Double? = nil,
    presentsGlobalPlayer: Bool = false
  ) {
    let loggedMessageId = messageId ?? "-"
    let loggedMedia = shortMediaURL(mediaURL)
    NSLog(
      "[ChatListView] voice tap messageId=%@ chatId=%@ mediaUrl=%@",
      loggedMessageId,
      chatId?.isEmpty == false ? chatId! : "-",
      loggedMedia
    )
    guard let messageId, !messageId.isEmpty, let mediaURL, !mediaURL.isEmpty else {
      NSLog("[ChatListView] voice tap ignored missing messageId/mediaUrl")
      return
    }

    if activeMessageId == messageId {
      if hasActivePlaybackEngine {
        if isPlaybackCurrentlyPlaying() {
          pausePlayback(updateCell: true)
          NSLog(
            "[ChatListView] voice pause messageId=%@ progress=%.3f", messageId, playbackProgress)
        } else {
          isPlaying = resumePlayback(updateCell: true)
          NSLog(
            "[ChatListView] voice resume messageId=%@ progress=%.3f", messageId, playbackProgress)
        }
        return
      } else if activeDownloadTask != nil {
        NSLog("[ChatListView] voice cancel download messageId=%@", messageId)
        stopActivePlayback(resetProgress: true)
        return
      } else if resolvingMessageId == messageId {
        // First play of a SoundCloud track blocks ~5–10s while the server downloads +
        // re-hosts it. Ignore taps during the grace window so an impatient re-tap does NOT
        // cancel the in-flight resolve (that used to kill it every time and it never played).
        // Only once it's clearly stuck does a tap cancel.
        let elapsed = CACurrentMediaTime() - resolvingStartedAt
        if elapsed < resolveCancelGraceSeconds {
          NSLog(
            "[ChatListView] voice tap during resolve — keeping it alive (%.1fs) messageId=%@",
            elapsed,
            messageId
          )
          return
        }
        NSLog("[ChatListView] voice cancel resolve (stuck %.1fs) messageId=%@", elapsed, messageId)
        stopActivePlayback(resetProgress: true)
        return
      }
    }

    // A known-broken source must NOT re-run the download on tap. The user already
    // saw the spinner→error once; tapping again only looped a doomed retry (and the
    // stream resolve can hang for seconds first). Surface the error immediately —
    // no spinner, no banner — and point them at re-sending. The latch is in-memory,
    // so relaunching clears it and a fresh tap retries (e.g. after a server-side fix).
    if failedMessageIds.contains(messageId) {
      NSLog(
        "[ChatListView] voice tap on broken source — error only, no retry messageId=%@",
        messageId
      )
      UINotificationFeedbackGenerator().notificationOccurred(.warning)
      cell?.applyVoiceDownloadFailedState()
      return
    }

    beginPlayback(
      cell: cell,
      messageId: messageId,
      chatId: chatId,
      mediaURL: mediaURL,
      mediaKey: mediaKey,
      fileName: fileName,
      title: title,
      subtitle: subtitle,
      artwork: artwork,
      duration: duration,
      presentsGlobalPlayer: presentsGlobalPlayer,
      suppressEmptySnapshotDuringTransition: false
    )
  }

  func toggleCurrentPlayback() {
    if hasActivePlaybackEngine {
      if isPlaybackCurrentlyPlaying() {
        pausePlayback(updateCell: true)
      } else {
        isPlaying = resumePlayback(updateCell: true)
      }
      return
    }

    if activeDownloadTask != nil {
      stopActivePlayback(resetProgress: true)
    }
  }

  func stopCurrentPlayback() {
    stopActivePlayback(resetProgress: true)
  }

  func playNextTrack() {
    guard let nextItem = adjacentQueueItem(step: 1, wraps: isRepeatEnabled) else { return }
    startQueueItem(nextItem, cell: nil)
  }

  func playPreviousTrack() {
    guard let previousItem = adjacentQueueItem(step: -1, wraps: isRepeatEnabled) else { return }
    startQueueItem(previousItem, cell: nil)
  }

  func selectQueuedTrack(_ trackId: String) {
    let trimmedTrackId = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTrackId.isEmpty else { return }
    if activeMessageId == trimmedTrackId {
      if hasActivePlaybackEngine, !isPlaybackCurrentlyPlaying() {
        _ = resumePlayback(updateCell: true)
      }
      return
    }
    // Registry first (live chat queue), then store-only fallback (sheet may list
    // persisted tracks that aren't in the in-memory registry yet).
    let item =
      ChatAudioQueueRegistry.shared.resolvedItem(
        trackId: trimmedTrackId,
        preferredChatId: activeChatId
      )
      ?? queueItemFromStoreTrack(trackId: trimmedTrackId)
    guard let item else {
      NSLog(
        "[MusicList] selectQueuedTrack miss trackId=%@ activeChat=%@",
        trimmedTrackId,
        activeChatId ?? "nil"
      )
      return
    }
    if queueOrderMode == .random {
      syncRandomizedQueueMessageIds(anchorMessageId: item.messageId, regenerate: true)
    }
    NSLog("[MusicList] selectQueuedTrack play trackId=%@", item.messageId)
    startQueueItem(item, cell: nil)
  }

  /// Build a playable queue item from the persistent music store when the in-memory
  /// registry doesn't have the row (common after cold open before cells re-register).
  private func queueItemFromStoreTrack(trackId: String) -> ChatAudioQueueItem? {
    guard let track = NativeMusicPlayerStore.shared.getTrack(trackId: trackId) else { return nil }
    let mediaURL =
      (track.localURI?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
        $0.isEmpty ? nil : $0
      }
      ?? (track.streamURL?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
        $0.isEmpty ? nil : $0
      }
      ?? (track.previewURL?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
        $0.isEmpty ? nil : $0
      }
    guard let mediaURL, !mediaURL.isEmpty else { return nil }
    let chatId =
      track.links["chat_id"]
      ?? track.links["chatId"]
      ?? activeChatId
      ?? ""
    let trimmedChatId = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedChatId.isEmpty else { return nil }
    return ChatAudioQueueItem(
      chatId: trimmedChatId,
      messageId: track.trackId,
      mediaURL: mediaURL,
      mediaKey: nil,
      fileName: nil,
      title: track.title,
      subtitle: track.artist,
      artwork: ChatAudioQueueRegistry.shared.artwork(for: track.trackId, in: trimmedChatId),
      duration: track.durationSeconds ?? 0.0,
      track: track
    )
  }

  func seek(toSeconds seconds: Double) {
    let clamped = max(0.0, seconds)
    let duration = currentPlaybackDuration()
    let targetTime = max(0.0, min(duration > 0.0 ? duration : clamped, clamped))
    if let player {
      player.currentTime = targetTime
      playbackProgress = duration > 0.0 ? CGFloat(targetTime / duration) : 0.0
      activeCell?.applyVoicePlaybackState(
        isPlaying: player.isPlaying,
        progress: playbackProgress,
        level: player.isPlaying ? max(level, 0.18) : 0.0
      )
    } else if let streamingPlayer {
      let cmTime = CMTime(seconds: targetTime, preferredTimescale: 600)
      streamingPlayer.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
      playbackProgress = duration > 0.0 ? CGFloat(targetTime / duration) : 0.0
      activeCell?.applyVoicePlaybackState(
        isPlaying: streamingPlayer.timeControlStatus == .playing,
        progress: playbackProgress,
        level: streamingPlayer.timeControlStatus == .playing ? max(level, 0.18) : 0.0
      )
    }
    publishSnapshot(forceNowPlaying: true)
  }

  func refreshCurrentSnapshotIfNeeded(forChatId chatId: String) {
    let trimmedChatId = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedChatId.isEmpty, activeChatId == trimmedChatId else { return }
    syncRandomizedQueueMessageIds(anchorMessageId: activeMessageId, regenerate: false)
    publishSnapshot(forceNowPlaying: true)
  }

  func currentPlaybackRate() -> Double {
    playbackRate
  }

  func setPlaybackRate(_ value: Double) {
    let nextRate = max(1.0, min(2.0, value))
    playbackRate = nextRate
    if let player {
      player.enableRate = true
      player.rate = Float(nextRate)
    }
    if let streamingPlayer, isPlaying {
      streamingPlayer.playImmediately(atRate: Float(nextRate))
    }
    publishSnapshot(forceNowPlaying: true)
  }

  func cyclePlaybackRate() {
    let rates: [Double] = [1.0, 1.5, 2.0]
    let index = rates.firstIndex(where: { abs($0 - playbackRate) < 0.05 }) ?? 0
    let nextRate = rates[(index + 1) % rates.count]
    setPlaybackRate(nextRate)
  }

  func currentQueueOrderMode() -> NativeMusicPlayerQueueOrderMode {
    queueOrderMode
  }

  func repeatEnabled() -> Bool {
    isRepeatEnabled
  }

  func toggleQueueOrderMode() {
    queueOrderMode = queueOrderMode.next()
    syncRandomizedQueueMessageIds(
      anchorMessageId: activeMessageId,
      regenerate: queueOrderMode == .random
    )
    publishSnapshot(forceNowPlaying: true)
  }

  func toggleRepeatEnabled() {
    isRepeatEnabled.toggle()
    publishSnapshot(forceNowPlaying: true)
  }

  func displayQueueTracks() -> [NativeMusicPlayerTrack] {
    orderedQueueItems().map(\.track)
  }

  private func orderedQueueItems() -> [ChatAudioQueueItem] {
    let baseItems = applyManualQueueOrder(to: resolvedQueueItems())
    switch queueOrderMode {
    case .forward:
      return baseItems
    case .reverse:
      return Array(baseItems.reversed())
    case .random:
      syncRandomizedQueueMessageIds(anchorMessageId: activeMessageId, regenerate: false)
      let itemsByMessageId = Dictionary(uniqueKeysWithValues: baseItems.map { ($0.messageId, $0) })
      return randomizedQueueMessageIds.compactMap { itemsByMessageId[$0] }
    }
  }

  /// Reorders items to the manual drag order for the active chat; any items not named in
  /// the manual order keep their base position at the end (newly-arrived tracks).
  private func applyManualQueueOrder(to items: [ChatAudioQueueItem]) -> [ChatAudioQueueItem] {
    guard let chatId = activeChatId, let order = manualQueueOrderByChatId[chatId], !order.isEmpty
    else { return items }
    let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
    return items.enumerated().sorted { lhs, rhs in
      let lr = rank[lhs.element.messageId] ?? (order.count + lhs.offset)
      let rr = rank[rhs.element.messageId] ?? (order.count + rhs.offset)
      return lr < rr
    }.map(\.element)
  }

  private func resolvedQueueItems() -> [ChatAudioQueueItem] {
    guard let activeMessageId else { return [] }
    guard
      let resolvedChatId = ChatAudioQueueRegistry.shared.resolvedChatId(
        for: activeMessageId,
        preferredChatId: activeChatId
      )
    else {
      return []
    }
    activeChatId = resolvedChatId
    return ChatAudioQueueRegistry.shared.items(for: resolvedChatId)
  }

  private func syncRandomizedQueueMessageIds(anchorMessageId: String?, regenerate: Bool) {
    let baseIds = resolvedQueueItems().map(\.messageId)
    let expected = Set(baseIds)
    let current = Set(randomizedQueueMessageIds)
    let needsRefresh =
      regenerate
      || randomizedQueueMessageIds.count != baseIds.count
      || current != expected

    guard needsRefresh else { return }

    var shuffledIds = baseIds
    if let anchorMessageId,
      let anchorIndex = shuffledIds.firstIndex(of: anchorMessageId)
    {
      shuffledIds.remove(at: anchorIndex)
      shuffledIds.shuffle()
      shuffledIds.insert(anchorMessageId, at: 0)
    } else {
      shuffledIds.shuffle()
    }
    randomizedQueueMessageIds = shuffledIds
  }

  private func startQueueItem(_ item: ChatAudioQueueItem, cell: VoicePlayableCell?) {
    // Drop quiet prefetch (keep any completed cache file) so this track owns the
    // active stream/download path cleanly.
    cancelPrefetch(keepFile: true)
    beginPlayback(
      cell: cell,
      messageId: item.messageId,
      chatId: item.chatId,
      mediaURL: item.mediaURL,
      mediaKey: item.mediaKey,
      fileName: item.fileName,
      title: item.title,
      subtitle: item.subtitle,
      artwork: item.artwork,
      duration: item.duration,
      presentsGlobalPlayer: true,
      suppressEmptySnapshotDuringTransition: true,
      preserveQueueOrder: true,
      remoteFallbackURL: item.track.streamURL ?? item.track.previewURL
    )
  }

  private func adjacentQueueItem(step: Int, wraps: Bool) -> ChatAudioQueueItem? {
    guard step != 0 else { return nil }
    guard let activeMessageId else { return nil }
    let items = orderedQueueItems()
    guard !items.isEmpty else {
      return nil
    }
    guard let currentIndex = items.firstIndex(where: { $0.messageId == activeMessageId }) else {
      return nil
    }
    let nextIndex = currentIndex + step
    let nextItem: ChatAudioQueueItem?
    if items.indices.contains(nextIndex) {
      nextItem = items[nextIndex]
    } else if wraps {
      nextItem = step > 0 ? items.first : items.last
    } else {
      nextItem = nil
    }
    activeChatId = nextItem?.chatId
    return nextItem
  }

  private func beginPlayback(
    cell: VoicePlayableCell?,
    messageId: String?,
    chatId: String? = nil,
    mediaURL: String?,
    mediaKey: String? = nil,
    fileName: String? = nil,
    title: String? = nil,
    subtitle: String? = nil,
    artwork: UIImage? = nil,
    duration: Double? = nil,
    presentsGlobalPlayer: Bool = false,
    suppressEmptySnapshotDuringTransition: Bool = false,
    preserveQueueOrder: Bool = false,
    remoteFallbackURL: String? = nil
  ) {
    stopActivePlayback(
      resetProgress: true,
      suppressSnapshot: suppressEmptySnapshotDuringTransition,
      // We are about to activate the session again — never pay the deactivate here.
      deactivateSession: false
    )
    let beganAt = CACurrentMediaTime()
    playbackRequestedAt = beganAt
    activeChatId = presentsGlobalPlayer ? normalizedChatAudioId(chatId) : nil
    if presentsGlobalPlayer && queueOrderMode == .random && !preserveQueueOrder {
      syncRandomizedQueueMessageIds(anchorMessageId: messageId, regenerate: true)
    }
    activeMediaURL = mediaURL
    activeRemoteFallbackURL = remoteFallbackURL
    activeMediaKey = mediaKey
    activeFileName = fileName
    activeTitle = title
    activeSubtitle = subtitle
    activeArtwork = artwork
    activeDuration = max(0.0, duration ?? 0.0)
    self.presentsGlobalPlayer = presentsGlobalPlayer
    activeCell = cell

    guard let messageId, !messageId.isEmpty, let mediaURL, !mediaURL.isEmpty else {
      publishSnapshot(forceNowPlaying: true)
      return
    }

    guard let resolvedURL = resolveAudioURL(from: mediaURL) else {
      NSLog(
        "[ChatListView] voice resolveAudioURL failed messageId=%@ raw=%@",
        messageId,
        shortMediaURL(mediaURL)
      )
      publishSnapshot(forceNowPlaying: true)
      return
    }
    NSLog(
      "[ChatListView] voice resolved URL messageId=%@ isFile=%@ resolveMs=%.0f path=%@",
      messageId,
      resolvedURL.isFileURL.description,
      (CACurrentMediaTime() - beganAt) * 1000.0,
      resolvedURL.path
    )

    if !resolvedURL.isFileURL {
      playRemoteURL(
        resolvedURL,
        messageId: messageId,
        cell: cell,
        mediaKey: mediaKey,
        fileName: fileName
      )
      return
    }

    // The sandbox remap happily rewrites a path from a dead container into the live
    // one whether or not anything is there. Resolving to a file that does not exist
    // used to end the tap in a decode error; take the track's remote source instead.
    if !FileManager.default.fileExists(atPath: resolvedURL.path),
      let remoteURL = remoteRetryURL(for: messageId)
    {
      NSLog(
        "[ChatListView] voice local miss → remote messageId=%@ missing=%@",
        messageId,
        resolvedURL.lastPathComponent
      )
      dropStaleLocalURIIfRemoteExists(messageId: messageId)
      playRemoteURL(
        remoteURL, messageId: messageId, cell: cell, mediaKey: mediaKey, fileName: fileName)
      return
    }

    playLocalURL(resolvedURL, messageId: messageId, cell: cell)
  }

  /// First usable http(s) source for a message: the raw media URL if it was remote,
  /// then the fallback handed in with the queue item, then the store's own stream /
  /// preview URLs. Deliberately ignores file URLs — that is the thing that failed.
  private func remoteRetryURL(for messageId: String) -> URL? {
    var candidates: [String?] = [activeMediaURL, activeRemoteFallbackURL]
    if let track = NativeMusicPlayerStore.shared.getTrack(trackId: messageId) {
      candidates.append(track.streamURL)
      candidates.append(track.previewURL)
    }
    for candidate in candidates {
      guard
        let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
        !raw.isEmpty,
        let url = Self.absoluteAPIURL(fromRelativeOrAbsolute: raw),
        let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https"
      else { continue }
      return url
    }
    return nil
  }

  /// Forget a `localURI` that no longer resolves — but only when the track still has a
  /// remote source to re-fetch from, so a locally-recorded note never loses its only
  /// pointer.
  private func dropStaleLocalURIIfRemoteExists(messageId: String) {
    guard let track = NativeMusicPlayerStore.shared.getTrack(trackId: messageId),
      track.localURI != nil,
      (track.streamURL?.isEmpty == false) || (track.previewURL?.isEmpty == false)
    else { return }
    _ = NativeMusicPlayerStore.shared.updateLocalURI(trackId: messageId, localURI: nil)
  }

  private func advanceToNextQueuedTrackIfAvailable() -> Bool {
    guard let nextItem = adjacentQueueItem(step: 1, wraps: isRepeatEnabled) else { return false }
    startQueueItem(nextItem, cell: nil)
    return true
  }

  /// Quietly cache the upcoming track so auto-next (and manual next) can start without
  /// waiting on a cold download. Never drives the active download ring / snapshot bytes.
  private func prefetchUpcomingTrackIfNeeded() {
    guard presentsGlobalPlayer else { return }
    guard let nextItem = adjacentQueueItem(step: 1, wraps: false) else { return }
    let messageId = nextItem.messageId
    if prefetchMessageId == messageId, prefetchDownloadTask != nil { return }
    if activeMessageId == messageId { return }

    guard let resolvedURL = resolveAudioURL(from: nextItem.mediaURL) else { return }
    if resolvedURL.isFileURL { return }

    let localURL = cachedRemoteVoiceURL(for: resolvedURL, fileName: nextItem.fileName)
    if FileManager.default.fileExists(atPath: localURL.path) {
      _ = NativeMusicPlayerStore.shared.updateLocalURI(
        trackId: messageId, localURI: localURL.absoluteString)
      return
    }

    cancelPrefetch(keepFile: true)
    prefetchMessageId = messageId

    // Backend /api/music/stream needs resolve-or-auth; prefer the same public resolve
    // path as live playback so cache keys stay stable.
    if let videoId = ChatMusicStreamResolver.videoId(fromBackendStreamURL: resolvedURL) {
      var headers: [String: String] = [:]
      if let authHeader = ChatEngine.shared.authorizationHeaderForAPI() {
        headers["Authorization"] = authHeader
      }
      ChatMusicStreamResolver.shared.resolve(videoId: videoId, headers: headers) {
        [weak self] _ in
        guard let self else { return }
        guard self.prefetchMessageId == messageId else { return }
        // Always cache via the stable backend URL (auth attached in startQuietPrefetch).
        self.startQuietPrefetchDownload(
          remoteURL: resolvedURL,
          destinationURL: localURL,
          messageId: messageId,
          mediaKey: nextItem.mediaKey
        )
      }
      return
    }

    startQuietPrefetchDownload(
      remoteURL: resolvedURL,
      destinationURL: localURL,
      messageId: messageId,
      mediaKey: nextItem.mediaKey
    )
  }

  private func startQuietPrefetchDownload(
    remoteURL: URL,
    destinationURL: URL,
    messageId: String,
    mediaKey: String?
  ) {
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      _ = NativeMusicPlayerStore.shared.updateLocalURI(
        trackId: messageId, localURI: destinationURL.absoluteString)
      prefetchMessageId = nil
      return
    }

    var request = URLRequest(url: remoteURL)
    request.timeoutInterval = 120
    if let host = remoteURL.host?.lowercased(),
      host == "vibegram.io" || host.hasSuffix(".vibegram.io"),
      let authHeader = ChatEngine.shared.authorizationHeaderForAPI()
    {
      request.setValue(authHeader, forHTTPHeaderField: "Authorization")
    }
    if let sourceHeaders = VoicePlayProgressViewSourceHeaders.headers(for: remoteURL) {
      for (field, value) in sourceHeaders {
        request.setValue(value, forHTTPHeaderField: field)
      }
    }

    NSLog(
      "[MusicList] prefetch start messageId=%@ url=%@",
      messageId,
      remoteURL.host ?? remoteURL.absoluteString
    )
    let task = VibeHTTP.shared.downloadTask(with: request) { [weak self] tempURL, response, error in
      guard let self else { return }
      DispatchQueue.main.async {
        guard self.prefetchMessageId == messageId else { return }
        defer {
          self.prefetchDownloadTask = nil
          if self.prefetchMessageId == messageId {
            self.prefetchMessageId = nil
          }
        }
        guard let tempURL, error == nil else {
          NSLog(
            "[MusicList] prefetch failed messageId=%@ error=%@",
            messageId,
            String(describing: error)
          )
          return
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
          NSLog(
            "[MusicList] prefetch HTTP %d messageId=%@",
            http.statusCode,
            messageId
          )
          return
        }
        let contentType =
          (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased()
          ?? ""
        if contentType.contains("mpegurl") || remoteURL.pathExtension.lowercased() == "m3u8" {
          // HLS is stream-only; nothing useful to cache here.
          return
        }
        if contentType.contains("text/html") || contentType.contains("application/json") {
          return
        }
        let fileSize =
          (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
        guard fileSize >= 100 else { return }

        do {
          if let mediaKey, !mediaKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let encryptedData = try Data(contentsOf: tempURL, options: [.mappedIfSafe])
            guard
              let decryptedData = chatMediaDecryptedDataIfNeeded(
                encryptedData, mediaKey: mediaKey)
            else { return }
            try decryptedData.write(to: destinationURL, options: [.atomic])
            try? FileManager.default.removeItem(at: tempURL)
          } else {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
              try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
          }
          _ = NativeMusicPlayerStore.shared.updateLocalURI(
            trackId: messageId, localURI: destinationURL.absoluteString)
          NSLog(
            "[MusicList] prefetch ready messageId=%@ bytes=%lld",
            messageId,
            fileSize
          )
        } catch {
          NSLog(
            "[MusicList] prefetch write failed messageId=%@ error=%@",
            messageId,
            String(describing: error)
          )
        }
      }
    }
    prefetchDownloadTask = task
    task.resume()
  }

  private func cancelPrefetch(keepFile: Bool) {
    prefetchDownloadTask?.cancel()
    prefetchDownloadTask = nil
    prefetchMessageId = nil
    _ = keepFile
  }

  private func playRemoteURL(
    _ url: URL,
    messageId: String,
    cell: VoicePlayableCell?,
    mediaKey: String?,
    fileName: String?
  ) {
    let localURL = cachedRemoteVoiceURL(for: url, fileName: fileName)

    if FileManager.default.fileExists(atPath: localURL.path) {
      playLocalURL(localURL, messageId: messageId, cell: cell)
      return
    }

    // For all remote files: start streaming immediately for rapid first-byte playback.
    // Download runs concurrently in background:
    //   - no mediaKey: caches a clean copy for future plays.
    //   - mediaKey (encrypted): download+decrypt gives a seekable local file; if the
    //     remote URL actually serves plaintext audio the stream plays fine, otherwise
    //     streaming fails gracefully and finishDownload auto-plays the decrypted file.
    let trimmedMediaKey = mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    // Backend /api/music/stream sits behind API auth — AVPlayer cannot attach a bearer
    // (401 / -1013). Resolve the PUBLIC URL first via /api/music/info (handles cache-fill
    // + direct yt-dlp fallback), THEN download that public URL. Downloading the backend
    // URL while resolve is still in flight used to race a 500 JSON body into the
    // terminal-failure latch (retry just re-hit the same race).
    if let videoId = ChatMusicStreamResolver.videoId(fromBackendStreamURL: url) {
      activeMessageId = messageId
      activeCell = cell
      activeMediaURL = url.absoluteString
      resolvingMessageId = messageId
      resolvingStartedAt = CACurrentMediaTime()
      pushDownloadState(to: cell, needsDownload: true, isDownloading: true)
      publishSnapshot(forceNowPlaying: true)

      var headers: [String: String] = [:]
      if let authHeader = ChatEngine.shared.authorizationHeaderForAPI() {
        headers["Authorization"] = authHeader
      }
      ChatMusicStreamResolver.shared.resolve(videoId: videoId, headers: headers) {
        [weak self] publicURL in
        guard let self else { return }
        guard self.activeMessageId == messageId else { return }
        // Keep resolvingMessageId set until stream + download are both kicked off so
        // reconfigure/bind cannot blank the spinner between resolve and transfer start.

        if let publicURL {
          // AVPlayer streams both direct audio AND HLS manifests. Stream public for
          // instant playback. ALWAYS cache via the STABLE backend /api/music/stream URL
          // (auth + re-hosted file) — downloading the public CDN URL often hits HLS
          // `.m3u8` which is abandoned, so reopen always MISSed the cache and re-asked
          // the user to "download" media they already played.
          self.startStreamingRemotePlayback(publicURL, messageId: messageId, cell: cell)
          self.beginRemoteDownloadTask(
            url,
            messageId: messageId,
            mediaKey: nil,
            fileName: fileName,
            autoPlayWhenFinished: false,
            cacheDestinationURL: localURL
          )
          self.resolvingMessageId = nil
          self.pushDownloadState(
            to: cell,
            needsDownload: self.activeDownloadTask != nil,
            isDownloading: self.activeDownloadTask != nil || self.streamingPlayer != nil
          )
        } else {
          // No public URL — download the authed backend stream (bearer attached for our host).
          NSLog(
            "[ChatListView] music resolve miss messageId=%@ videoId=%@ — trying backend stream",
            messageId,
            videoId
          )
          self.beginRemoteDownloadTask(
            url,
            messageId: messageId,
            mediaKey: nil,
            fileName: fileName,
            autoPlayWhenFinished: true,
            cacheDestinationURL: localURL
          )
          self.resolvingMessageId = nil
          self.pushDownloadState(
            to: cell,
            needsDownload: self.activeDownloadTask != nil,
            isDownloading: self.activeDownloadTask != nil
          )
        }
      }
      return
    }

    startStreamingRemotePlayback(url, messageId: messageId, cell: cell)
    beginRemoteDownloadTask(
      url,
      messageId: messageId,
      mediaKey: trimmedMediaKey.isEmpty ? nil : mediaKey,
      fileName: fileName,
      autoPlayWhenFinished: !trimmedMediaKey.isEmpty
    )
  }

  /// True while resolve/download is still active for the playing message (badge must stay on).
  private func isMediaTransferActive(for messageId: String?) -> Bool {
    guard let messageId, !messageId.isEmpty, activeMessageId == messageId else { return false }
    return activeDownloadTask != nil || resolvingMessageId == messageId
  }

  private func startStreamingRemotePlayback(
    _ url: URL,
    messageId: String,
    cell: VoicePlayableCell?
  ) {
    cleanupStreamingPlayer()
    activeMessageId = messageId
    activeMediaURL = url.absoluteString
    activeCell = cell
    clearActiveDownloadByteState()
    playbackProgress = 0.0
    level = 0.0
    isPlaying = false

    do {
      try configurePlaybackSession()
    } catch {
      NSLog(
        "[ChatListView] voice stream session failed messageId=%@ error=%@",
        messageId,
        String(describing: error)
      )
    }

    // SoundCloud's CDN hotlink-protects its HLS with a Referer/User-Agent gate (a bare
    // request 403s "Forbidden"). Match what the server's yt-dlp sends so AVPlayer can fetch
    // the manifest + segments.
    let item: AVPlayerItem
    if let headers = VoicePlayProgressViewSourceHeaders.headers(for: url) {
      let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
      item = AVPlayerItem(asset: asset)
    } else {
      item = AVPlayerItem(url: url)
    }
    let nextPlayer = AVPlayer(playerItem: item)
    // Play as soon as the first chunk is buffered rather than waiting to minimise stalling.
    // Gives near-instant audio start on reliable connections; may stall briefly on slow links
    // but the user hears sound much sooner than with the default true.
    nextPlayer.automaticallyWaitsToMinimizeStalling = false
    streamingPlayer = nextPlayer

    streamingPlayerStatusObservation = item.observe(\.status, options: [.initial, .new]) {
      [weak self] item, _ in
      guard let self else { return }
      DispatchQueue.main.async {
        switch item.status {
        case .readyToPlay:
          if item.duration.seconds.isFinite, item.duration.seconds > 0.0 {
            self.activeDuration = max(self.activeDuration, item.duration.seconds)
          }
          _ = self.resumePlayback(updateCell: true)
          self.prefetchUpcomingTrackIfNeeded()
        case .failed:
          NSLog(
            "[ChatListView] voice stream failed messageId=%@ error=%@",
            messageId,
            String(describing: item.error)
          )
          if self.activeDownloadTask != nil {
            // A background download is already running (encrypted/fallback path).
            // Just tear down the non-working AVPlayer; finishDownload will play
            // the decrypted local file once the download completes.
            NSLog(
              "[ChatListView] voice stream failed – keeping download alive messageId=%@",
              messageId
            )
            self.cleanupStreamingPlayer()
            self.isPlaying = false
            self.level = 0.0
            self.pushDownloadState(
              to: self.activeCell,
              needsDownload: true,
              isDownloading: true
            )
            self.activeCell?.applyVoicePlaybackState(
              isPlaying: false, progress: 0.0, level: 0.0
            )
            self.publishSnapshot(forceNowPlaying: true)
          } else {
            self.markDownloadFailed(messageId: messageId)
          }
        default:
          break
        }
      }
    }

    streamingTimeObserver = nextPlayer.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      let duration = self.currentPlaybackDuration()
      let currentTime = self.currentPlaybackTime()
      self.playbackProgress = duration > 0.0 ? CGFloat(currentTime / duration) : 0.0
      self.level = self.isPlaybackCurrentlyPlaying() ? 0.18 : 0.0
      self.isPlaying = self.isPlaybackCurrentlyPlaying()
      let isLoading = self.isMediaTransferActive(for: self.activeMessageId)
      // Spinner stays up for the whole transfer (resolve + download), even while
      // audio is already streaming. Only drop it when transfer is fully idle.
      self.pushDownloadState(
        to: self.activeCell,
        needsDownload: isLoading,
        isDownloading: isLoading
      )
      self.activeCell?.applyVoicePlaybackState(
        isPlaying: self.isPlaying,
        progress: self.playbackProgress,
        level: self.level
      )
      self.publishSnapshot()
    }

    streamingEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      if !self.advanceToNextQueuedTrackIfAvailable() {
        self.stopActivePlayback(resetProgress: true)
      }
    }

    // Show a buffering/loading indicator while AVPlayer is connecting.
    // The time observer will clear this once the first chunk starts playing.
    pushDownloadState(to: cell, needsDownload: true, isDownloading: true)
    cell?.applyVoicePlaybackState(isPlaying: false, progress: 0.0, level: 0.0)
    ensureDisplayLink()
    publishSnapshot(forceNowPlaying: true)
  }

  private func beginRemoteDownloadTask(
    _ url: URL,
    messageId: String,
    mediaKey: String?,
    fileName: String?,
    autoPlayWhenFinished: Bool,
    cacheDestinationURL: URL? = nil
  ) {
    // cacheDestinationURL keeps the cache keyed on the STABLE backend URL when we
    // download a resolved (ephemeral) public URL instead.
    let localURL = cacheDestinationURL ?? cachedRemoteVoiceURL(for: url, fileName: fileName)
    var request = URLRequest(url: url)
    request.timeoutInterval = 60
    // Our media endpoints (e.g. /api/music/stream/:id) sit behind api auth and 401
    // without a bearer. Attach the token only for our own host so it never leaks to
    // the Supabase CDN we redirect to (or any third-party media host).
    if let host = url.host?.lowercased(),
      host == "vibegram.io" || host.hasSuffix(".vibegram.io"),
      let authHeader = ChatEngine.shared.authorizationHeaderForAPI()
    {
      request.setValue(authHeader, forHTTPHeaderField: "Authorization")
    }
    // SoundCloud CDN hotlink-protects with a Referer/UA gate (bare request → 403 "Forbidden").
    if let sourceHeaders = VoicePlayProgressViewSourceHeaders.headers(for: url) {
      for (field, value) in sourceHeaders {
        request.setValue(value, forHTTPHeaderField: field)
      }
    }
    let task = VibeHTTP.shared.downloadTask(with: request) { [weak self] tempURL, response, error in
    // Note: progress observation is set up below after task is assigned to activeDownloadTask.
      guard let self, let tempURL = tempURL, error == nil else {
        NSLog(
          "[ChatListView] voice download failed url=%@ error=%@", url.absoluteString,
          String(describing: error))
        DispatchQueue.main.async {
          guard self?.activeMessageId == messageId else { return }
          if self?.hasActivePlaybackEngine == true {
            self?.activeDownloadTask = nil
            self?.clearActiveDownloadByteState()
            self?.publishSnapshot(forceNowPlaying: true)
          } else {
            self?.markDownloadFailed(messageId: messageId)
          }
        }
        return
      }

      if let httpResponse = response as? HTTPURLResponse {
        let statusCode = httpResponse.statusCode
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        NSLog(
          "[ChatListView] voice download response messageId=%@ status=%d contentType=%@ bytes=%lld",
          messageId,
          statusCode,
          contentType,
          (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
        )
        if !(200...299).contains(statusCode) {
          NSLog(
            "[ChatListView] voice download HTTP error messageId=%@ status=%d",
            messageId,
            statusCode
          )
          DispatchQueue.main.async {
            guard self.activeMessageId == messageId else { return }
            if self.hasActivePlaybackEngine {
              self.activeDownloadTask = nil
              self.clearActiveDownloadByteState()
              self.publishSnapshot(forceNowPlaying: true)
            } else {
              self.markDownloadFailed(messageId: messageId)
            }
          }
          return
        }
        let lowerCT = contentType.lowercased()
        // HLS manifest (SoundCloud): NOT a downloadable audio file — it must be streamed by
        // AVPlayer (which we already started in parallel). Abandon the cache download quietly;
        // never mark it failed or evict, or we'd loop download→fail→retry on a healthy stream.
        let isHLSManifest =
          lowerCT.contains("mpegurl") || url.pathExtension.lowercased() == "m3u8"
        if isHLSManifest {
          NSLog(
            "[ChatListView] voice download is HLS manifest — streaming instead messageId=%@ contentType=%@",
            messageId,
            contentType
          )
          DispatchQueue.main.async {
            guard self.activeMessageId == messageId else { return }
            self.activeDownloadTask = nil
            self.clearActiveDownloadByteState()
            self.publishSnapshot(forceNowPlaying: true)
          }
          return
        }
        if lowerCT.contains("text/html") || lowerCT.contains("application/json") {
          NSLog(
            "[ChatListView] voice download got non-audio content messageId=%@ contentType=%@",
            messageId,
            contentType
          )
          DispatchQueue.main.async {
            guard self.activeMessageId == messageId else { return }
            if self.hasActivePlaybackEngine {
              self.activeDownloadTask = nil
              self.clearActiveDownloadByteState()
              self.publishSnapshot(forceNowPlaying: true)
            } else {
              self.markDownloadFailed(messageId: messageId)
            }
          }
          return
        }
      }

      let fileSize =
        (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
      if fileSize < 100 {
        NSLog(
          "[ChatListView] voice download too small messageId=%@ bytes=%lld",
          messageId,
          fileSize
        )
        DispatchQueue.main.async {
          guard self.activeMessageId == messageId else { return }
          if self.hasActivePlaybackEngine {
            self.activeDownloadTask = nil
            self.clearActiveDownloadByteState()
            self.publishSnapshot(forceNowPlaying: true)
          } else {
            // A ~100-byte body is a broken source (e.g. an error JSON), not a real file —
            // latch it as failed so the badge shows the error immediately and the next tap
            // surfaces the error instead of re-running the doomed spinner→resolve→download.
            self.markDownloadFailed(messageId: messageId)
          }
        }
        return
      }

      do {
        let destinationURL: URL
        if let mediaKey, !mediaKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          let encryptedData = try Data(contentsOf: tempURL, options: [.mappedIfSafe])
          guard let decryptedData = chatMediaDecryptedDataIfNeeded(encryptedData, mediaKey: mediaKey)
          else {
            throw NSError(
              domain: "VoiceBubblePlaybackCoordinator",
              code: 31,
              userInfo: [NSLocalizedDescriptionKey: "voice decrypt failed"])
          }
          try decryptedData.write(to: localURL, options: [.atomic])
          destinationURL = localURL
          try? FileManager.default.removeItem(at: tempURL)
        } else {
          if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
          }
          try FileManager.default.moveItem(at: tempURL, to: localURL)
          destinationURL = localURL
        }
        DispatchQueue.main.async {
          guard self.activeMessageId == messageId else { return }
          self.finishDownload(
            messageId: messageId,
            localMediaURL: destinationURL.absoluteString,
            autoPlayWhenFinished: autoPlayWhenFinished
          )
        }
      } catch {
        NSLog("[ChatListView] voice move failed error=%@", String(describing: error))
        DispatchQueue.main.async {
          guard self.activeMessageId == messageId else { return }
          if self.hasActivePlaybackEngine {
            self.activeDownloadTask = nil
            self.clearActiveDownloadByteState()
            self.publishSnapshot(forceNowPlaying: true)
          } else {
            self.stopActivePlayback(resetProgress: true)
          }
        }
      }
    }
    activeDownloadTask = task
    clearActiveDownloadByteState()
    // Drive the ring from real byte counts on task.progress (not coarse fractionCompleted alone).
    activeDownloadProgressObservation = task.progress.observe(
      \.fractionCompleted,
      options: [.initial, .new]
    ) { [weak self] progress, _ in
      guard let self else { return }
      DispatchQueue.main.async {
        guard self.activeMessageId == messageId, self.activeDownloadTask != nil else { return }
        let previousFraction = self.activeDownloadProgress
        self.ingestDownloadProgress(from: progress)
        guard self.shouldPublishDownloadProgressUpdate(previousFraction: previousFraction) else {
          return
        }
        self.pushDownloadState(
          to: self.activeCell,
          needsDownload: true,
          isDownloading: true
        )
        self.publishSnapshot()
      }
    }
    task.resume()
  }

  private func playLocalURL(_ url: URL, messageId: String, cell: VoicePlayableCell?) {
    do {
      try configurePlaybackSession()
      let nextPlayer = try AVAudioPlayer(contentsOf: url)
      nextPlayer.delegate = self
      nextPlayer.prepareToPlay()
      nextPlayer.enableRate = true
      nextPlayer.rate = Float(playbackRate)
      nextPlayer.isMeteringEnabled = true
      player = nextPlayer
      activeMessageId = messageId
      activeMediaURL = url.absoluteString
      activeCell = cell
      clearActiveDownloadByteState()
      activeDownloadTask = nil
      // Successful play clears the broken-file latch / attempt counter.
      failedMessageIds.remove(messageId)
      failedAttemptCounts.removeValue(forKey: messageId)
      poisonedCacheRetriedMessageIds.remove(messageId)
      playbackProgress = 0.0
      level = 0.0
      activeDuration = max(activeDuration, nextPlayer.duration)
      _ = NativeMusicPlayerStore.shared.updateLocalURI(trackId: messageId, localURI: url.absoluteString)
      isPlaying = nextPlayer.play()
      NSLog(
        "[ChatListView] voice play start messageId=%@ accepted=%@ duration=%.2f sinceTapMs=%.0f",
        messageId,
        isPlaying.description,
        nextPlayer.duration,
        (CACurrentMediaTime() - playbackRequestedAt) * 1000.0
      )
      ensureDisplayLink()
      // needsDownload false + isDownloading false → ring fills to 100% then morphs to play.
      pushDownloadState(to: cell, needsDownload: false, isDownloading: false)
      cell?.applyVoicePlaybackState(isPlaying: isPlaying, progress: 0.0, level: 0.0)
      publishSnapshot(forceNowPlaying: true)
      prefetchUpcomingTrackIfNeeded()
    } catch {
      NSLog(
        "[ChatListView] voice play failed messageId=%@ error=%@",
        messageId,
        String(describing: error)
      )
      // Anything that got us here may have been the session itself (another component
      // in the app can deactivate it under us) — drop the latches so the retry below,
      // and the next tap, reconfigure from scratch rather than trusting stale flags.
      didConfigurePlaybackCategory = false
      didActivateAudioSession = false
      // A cached voice/music file that won't decode is a poisoned cache: an earlier
      // failed fetch (e.g. an 84-byte JSON 500 body from /api/music/stream) got written
      // as ".m4a" and now replays forever (kAudioFileUnsupportedFileTypeError 'typ?').
      // Evict it so a clean copy is re-fetched — the download path validates status /
      // content-type / size, so it can't re-poison — then self-heal by retrying the
      // remote source ONCE per message, no second tap or reinstall needed.
      if isCachedVoiceFile(url) {
        try? FileManager.default.removeItem(at: url)
        NSLog(
          "[ChatListView] voice evicted poisoned cache messageId=%@ path=%@",
          messageId,
          url.path
        )
      }
      // The retry used to require `activeMediaURL` to be remote — but the whole
      // reason we are here is that it was a *local* path (a stale `localURI` the
      // sandbox remap pointed at a poisoned cache file). Look the remote source up
      // from the track instead, so evicting the bad file actually re-fetches a
      // good one rather than losing the media.
      dropStaleLocalURIIfRemoteExists(messageId: messageId)
      if !poisonedCacheRetriedMessageIds.contains(messageId),
        let remoteURL = remoteRetryURL(for: messageId)
      {
        poisonedCacheRetriedMessageIds.insert(messageId)
        NSLog(
          "[ChatListView] voice retry from remote messageId=%@ host=%@",
          messageId,
          remoteURL.host ?? "?"
        )
        playRemoteURL(
          remoteURL,
          messageId: messageId,
          cell: cell,
          mediaKey: activeMediaKey,
          fileName: activeFileName
        )
        return
      }
      stopActivePlayback(resetProgress: true)
    }
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    NSLog("[ChatListView] voice completed success=%@", flag.description)
    if !advanceToNextQueuedTrackIfAvailable() {
      stopActivePlayback(resetProgress: true)
    }
  }

  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    NSLog("[ChatListView] voice decode error=%@", String(describing: error))
    stopActivePlayback(resetProgress: true)
  }

  private func ensureDisplayLink() {
    if displayLink != nil {
      return
    }
    let link = CADisplayLink(target: self, selector: #selector(handleDisplayTick))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  @objc private func handleDisplayTick() {
    // This runs on the display link, in `.common` mode — i.e. it spends the SAME frame
    // budget the scroll is spending. The pair to [ScrollHitch]: anything over ~3ms here is
    // felt as scroll lag while audio plays, and this says so instead of leaving it to be
    // inferred. Only slow ticks log; a per-frame flood would itself be the hitch.
    let tickStartedAt = ProcessInfo.processInfo.systemUptime
    defer {
      let tickMs = (ProcessInfo.processInfo.systemUptime - tickStartedAt) * 1000.0
      if tickMs >= 3.0 {
        NSLog(
          "[PlaybackTick] %.1fms playing=%@ downloading=%@ msg=%@",
          tickMs, isPlaying.description, (activeDownloadTask != nil).description,
          String((activeMessageId ?? "-").prefix(8)))
      }
    }
    if let activeDownloadTask, player == nil, streamingPlayer == nil {
      let previousFraction = activeDownloadProgress
      ingestDownloadProgress(from: activeDownloadTask.progress)
      if shouldPublishDownloadProgressUpdate(previousFraction: previousFraction) {
        pushDownloadState(
          to: activeCell,
          needsDownload: true,
          isDownloading: true
        )
        activeCell?.applyVoicePlaybackState(isPlaying: false, progress: 0.0, level: 0.0)
        publishSnapshot()
      }
      return
    }
    if let streamingPlayer {
      let duration = currentPlaybackDuration()
      let currentTime = currentPlaybackTime()
      playbackProgress = duration > 0.0 ? CGFloat(currentTime / duration) : 0.0
      playbackProgress = max(0.0, min(1.0, playbackProgress))
      level = streamingPlayer.timeControlStatus == .playing ? 0.18 : 0.0
      isPlaying = streamingPlayer.timeControlStatus == .playing
      let isDownloading = activeDownloadTask != nil
      if isDownloading, let activeDownloadTask {
        ingestDownloadProgress(from: activeDownloadTask.progress)
      }
      pushDownloadState(
        to: activeCell,
        needsDownload: isDownloading,
        isDownloading: isDownloading
      )
      activeCell?.applyVoicePlaybackState(
        isPlaying: isPlaying,
        progress: playbackProgress,
        level: level
      )
      if streamingPlayer.currentItem?.status == .failed {
        stopActivePlayback(resetProgress: true)
        return
      }
      if !isPlaying && playbackProgress >= 0.999 {
        if !advanceToNextQueuedTrackIfAvailable() {
          stopActivePlayback(resetProgress: true)
        }
        return
      }
      publishSnapshot()
      return
    }
    guard let player else {
      stopActivePlayback(resetProgress: true)
      return
    }
    if player.duration > 0 {
      playbackProgress = CGFloat(player.currentTime / player.duration)
    } else {
      playbackProgress = 0.0
    }
    playbackProgress = max(0.0, min(1.0, playbackProgress))
    player.updateMeters()
    let db = player.averagePower(forChannel: 0)
    let minDb: Float = -48.0
    let normalized = (db - minDb) / (-minDb)
    level = max(0.0, min(1.0, CGFloat(normalized)))
    isPlaying = player.isPlaying
    if !player.isPlaying && playbackProgress >= 0.999 {
      if !advanceToNextQueuedTrackIfAvailable() {
        stopActivePlayback(resetProgress: true)
      }
      return
    }
    activeCell?.applyVoicePlaybackState(
      isPlaying: player.isPlaying, progress: playbackProgress, level: level
    )
    publishSnapshot()
  }

  private func finishDownload(
    messageId: String,
    localMediaURL: String,
    autoPlayWhenFinished: Bool = true
  ) {
    activeDownloadTask = nil
    activeDownloadProgressObservation?.invalidate()
    activeDownloadProgressObservation = nil
    // Snapshot byte fields go nil the moment download ends / playback begins.
    clearActiveDownloadByteState()
    _ = NativeMusicPlayerStore.shared.updateLocalURI(trackId: messageId, localURI: localMediaURL)
    guard activeMessageId == messageId else { return }
    // If a streaming player is alive and playing (or buffering), the user already
    // has audio; just cache the decrypted file without interrupting playback.
    if let sp = streamingPlayer,
      sp.timeControlStatus == .playing || sp.timeControlStatus == .waitingToPlayAtSpecifiedRate
    {
      // Morph the ring to play without a 0-reset, then leave streaming audio alone.
      pushDownloadState(to: activeCell, needsDownload: false, isDownloading: false)
      activeCell?.applyVoicePlaybackState(
        isPlaying: sp.timeControlStatus == .playing,
        progress: playbackProgress,
        level: sp.timeControlStatus == .playing ? max(level, 0.18) : 0.0
      )
      publishSnapshot(forceNowPlaying: true)
      return
    }
    // Streaming is gone or stalled – fall through and play the local file.
    if streamingPlayer != nil {
      cleanupStreamingPlayer()
    }
    let localURL: URL
    if let parsedURL = URL(string: localMediaURL), parsedURL.isFileURL {
      localURL = parsedURL
    } else {
      localURL = URL(fileURLWithPath: localMediaURL)
    }
    playLocalURL(localURL, messageId: messageId, cell: activeCell)
  }

  private func stopActivePlayback(
    resetProgress: Bool, suppressSnapshot: Bool = false, deactivateSession: Bool = true
  ) {
    let previousCell = activeCell
    let previousMessageId = activeMessageId
    let previousMediaURL = activeMediaURL
    shouldResumeAfterInterruption = false
    resolvingMessageId = nil
    activeDownloadTask?.cancel()
    activeDownloadTask = nil
    activeDownloadProgressObservation?.invalidate()
    activeDownloadProgressObservation = nil
    clearActiveDownloadByteState()
    let hadPlaybackEngine = player != nil || streamingPlayer != nil
    player?.stop()
    player = nil
    cleanupStreamingPlayer()
    audioSessionEpoch += 1
    let deactivateEpoch = audioSessionEpoch
    // mediaserverd XPC; off-main so audioPlayerDidFinishPlaying cannot hang the UI.
    if deactivateSession, hadPlaybackEngine, didActivateAudioSession {
      didActivateAudioSession = false
      DispatchQueue.global(qos: .utility).async { [weak self] in
        guard let self, deactivateEpoch == self.audioSessionEpoch else { return }
        try? AVAudioSession.sharedInstance().setActive(
          false, options: [.notifyOthersOnDeactivation])
      }
    }
    isPlaying = false
    displayLink?.invalidate()
    displayLink = nil
    if resetProgress {
      playbackProgress = 0.0
      level = 0.0
    }
    if let previousCell {
      applyIdleState(
        cell: previousCell,
        messageId: previousMessageId,
        mediaURL: previousMediaURL,
        mediaKey: activeMediaKey,
        fileName: activeFileName
      )
    }
    activeMessageId = nil
    // Keep chatId + prefetch across queue transitions so auto-next can resolve order
    // and a warm next-track cache isn't thrown away mid-hand-off.
    if !suppressSnapshot {
      activeChatId = nil
      cancelPrefetch(keepFile: true)
    }
    activeMediaURL = nil
    activeMediaKey = nil
    activeFileName = nil
    activeTitle = nil
    activeSubtitle = nil
    activeArtwork = nil
    activeDuration = 0.0
    if !suppressSnapshot {
      presentsGlobalPlayer = false
    }
    activeCell = nil
    if !suppressSnapshot {
      // A genuine stop resets the play-gate so the next fresh start waits for real
      // playback again. Queue transitions (suppressSnapshot) keep it latched so the
      // banner doesn't blink out between gapless tracks.
      bannerPlaybackStarted = false
      publishSnapshot(forceNowPlaying: true)
    }
  }

  private func cleanupStreamingPlayer() {
    if let timeObserver = streamingTimeObserver {
      streamingPlayer?.removeTimeObserver(timeObserver)
      streamingTimeObserver = nil
    }
    if let streamingEndObserver {
      NotificationCenter.default.removeObserver(streamingEndObserver)
      self.streamingEndObserver = nil
    }
    streamingPlayerStatusObservation?.invalidate()
    streamingPlayerStatusObservation = nil
    streamingPlayer?.pause()
    streamingPlayer = nil
  }

  private func mediaURLRequiresDownload(
    _ mediaURL: String?,
    mediaKey: String? = nil,
    fileName: String? = nil
  ) -> Bool {
    guard
      let mediaURL,
      let resolvedURL = resolveAudioURL(from: mediaURL)
    else {
      return false
    }
    guard !resolvedURL.isFileURL else {
      return false
    }
    let key = resolvedURL.absoluteString
    // HOT PATH — see the note on `seedRemoteVoiceCacheFromLocal`. A present file stays
    // present for the session, so that answer is final; an absent one is re-probed at most
    // a few times a second (a download landing pushes cell state explicitly anyway, so the
    // badge is never waiting on this probe to notice).
    if Self.voiceCachePresentKeys.contains(key) { return false }
    let now = ProcessInfo.processInfo.systemUptime
    if let lastProbe = Self.voiceCacheAbsentProbeAt[key], now - lastProbe < 0.5 {
      return true
    }
    Self.voiceCacheAbsentProbeAt[key] = now
    // The pair to [VoiceCache] SEED: same key function, so a MISS here after a SEED for
    // the same remote URL means the key drifted (signed params, host rewrite, extension
    // mismatch) rather than the file being absent.
    let slot = cachedRemoteVoiceURL(for: resolvedURL, fileName: fileName)
    let needsDownload = !FileManager.default.fileExists(atPath: slot.path)
    if !needsDownload {
      Self.voiceCachePresentKeys.insert(key)
      Self.voiceCacheAbsentProbeAt.removeValue(forKey: key)
    }
    // Log only when THIS url's cached-state actually flips. A single shared
    // last-signature slot thrashed when several music cells were probed in a loop
    // (each snapshot publish re-checks every audio cell): consecutive probes were
    // for different urls, so the slot never matched and every probe re-logged.
    // Keyed-by-url state logs each url once (MISS), then again only on miss→hit.
    if Self.lastVoiceCacheProbeState[key] != needsDownload {
      Self.lastVoiceCacheProbeState[key] = needsDownload
      NSLog(
        "[VoiceCache] %@ key=%@ remote=%@",
        needsDownload ? "MISS — will download" : "HIT — no download",
        chatStableCacheHash(key), key)
    }
    return needsDownload
  }

  /// De-dupes the cache probe log per remote url (the check runs on every cell
  /// configure and on every playback snapshot publish, for every audio cell).
  private static var lastVoiceCacheProbeState: [String: Bool] = [:]
  /// De-dupes the sandbox path-remap log, for the same reason.
  private static var lastVoicePathRemapLogged: String?
  /// Remote urls confirmed to have bytes on disk. Terminal for the session.
  private static var voiceCachePresentKeys: Set<String> = []
  /// Last time an absent url was probed, so the miss case is re-checked on a clock
  /// instead of on every caller.
  private static var voiceCacheAbsentProbeAt: [String: Double] = [:]
  /// Resolved vault slot per remote url. The resolve walks up to 24 legacy candidates and
  /// stats each one — far too expensive to repeat per frame, and its answer is stable.
  private static var voiceSlotCache: [String: URL] = [:]

  /// Public lookup for share/forward: durable voice/music cache slot if present.
  func resolvedCachedLocalURL(forRemote remoteURL: URL, fileName: String?) -> URL? {
    let slot = cachedRemoteVoiceURL(for: remoteURL, fileName: fileName)
    return FileManager.default.fileExists(atPath: slot.path) ? slot : nil
  }

  /// Seed the remote-keyed voice cache from the sender's original local file.
  /// A just-sent voice/music message briefly carries both the remote URL and the
  /// local file; once the server echo rebuilds the row from encrypted_content the
  /// localMediaUrl is dropped, and the bubble would otherwise show a download
  /// button for media the sender already owns. Copying the local file into the
  /// cache (keyed by the remote URL, the same place a download would land) keeps
  /// it playable without re-downloading — and survives the app-container UUID
  /// changing on rebuild, since the key is the remote URL hash, not a sandbox path.
  ///
  /// HOT PATH. Every visible voice/music cell calls this on every playback snapshot, and
  /// snapshots used to publish once per display frame — so the `fileExists` probes below ran
  /// 120x/second per audio cell and made scrolling stutter whenever anything was playing.
  /// The answer is per-URL stable for a session, so it is resolved once and remembered.
  func seedRemoteVoiceCacheFromLocal(
    localMediaURL: String?, remoteMediaURL: String?, fileName: String?
  ) {
    guard
      let remoteRaw = remoteMediaURL?.trimmingCharacters(in: .whitespacesAndNewlines),
      let remoteURL = URL(string: remoteRaw),
      let scheme = remoteURL.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else { return }
    let seedKey = remoteURL.absoluteString
    guard !Self.settledVoiceSeedKeys.contains(seedKey) else { return }
    let destURL = cachedRemoteVoiceURL(for: remoteURL, fileName: fileName)
    // Already cached (also the cheap early-out after the first successful seed).
    guard !FileManager.default.fileExists(atPath: destURL.path) else {
      Self.settledVoiceSeedKeys.insert(seedKey)
      return
    }
    guard
      let localRaw = localMediaURL?.trimmingCharacters(in: .whitespacesAndNewlines),
      !localRaw.isEmpty,
      let localURL = resolveAudioURL(from: localRaw),
      localURL.isFileURL,
      FileManager.default.fileExists(atPath: localURL.path)
    else {
      // No local original to copy from, and none will appear later — this row is a
      // received message. Settle it so the probe never runs for this url again.
      Self.settledVoiceSeedKeys.insert(seedKey)
      return
    }
    let srcPath = localURL.path
    let dstPath = destURL.path
    // Settle before dispatching so the copy is attempted once, not once per frame while
    // it is in flight; a failure un-settles it so a later configure can retry.
    Self.settledVoiceSeedKeys.insert(seedKey)
    DispatchQueue.global(qos: .utility).async {
      let fm = FileManager.default
      guard fm.fileExists(atPath: srcPath), !fm.fileExists(atPath: dstPath) else { return }
      do {
        try fm.copyItem(atPath: srcPath, toPath: dstPath)
        // The seed key must be byte-identical to the one the cold-launch resolve
        // computes, or this "fix" silently changes nothing. Log the hash at BOTH ends
        // so a device log answers that directly instead of by inference.
        let bytes = (try? fm.attributesOfItem(atPath: dstPath)[.size] as? Int64) ?? 0
        NSLog(
          "[VoiceCache] SEED key=%@ bytes=%lld remote=%@",
          chatStableCacheHash(remoteURL.absoluteString), bytes, remoteURL.absoluteString)
      } catch {
        NSLog(
          "[VoiceCache] SEED FAILED remote=%@ error=%@",
          remoteURL.absoluteString, error.localizedDescription)
        DispatchQueue.main.async {
          VoiceBubblePlaybackCoordinator.settledVoiceSeedKeys.remove(seedKey)
        }
      }
    }
  }

  /// Remote urls whose cache-seed question is answered for this session (already cached,
  /// nothing local to seed from, or the copy has been dispatched). Purely an optimisation:
  /// clearing it costs correctness nothing, it just re-runs the filesystem probes.
  fileprivate static var settledVoiceSeedKeys: Set<String> = []

  /// The vault slot for a remote voice note or music track: the existing file if there is one,
  /// otherwise the path a download should write to. Same identity the chat photo, the document,
  /// and the Settings cache screen use, so one track is never stored twice.
  private func cachedRemoteVoiceURL(for remoteURL: URL, fileName: String?) -> URL {
    let slotCacheKey = remoteURL.absoluteString + "|" + (fileName ?? "")
    if let cached = Self.voiceSlotCache[slotCacheKey] { return cached }
    let vault = VibeMediaVault.shared
    let identity = VibeMediaVault.identity(remoteURL: remoteURL)
    let preferredExt = (fileName as NSString?)?.pathExtension.lowercased()
    let remoteExt = remoteURL.pathExtension.lowercased()
    let ext =
      !(preferredExt?.isEmpty ?? true) ? preferredExt!
      : remoteExt == "enc" || remoteExt.isEmpty ? "m4a" : remoteExt
    // Pre-vault slots, in both the durable and the purgeable `voice-cache` folder: the old hash
    // of the full absoluteString as well as the stable-identity hash, under whichever audio
    // extension the file happened to get. A hit is moved into the vault, not re-downloaded.
    let legacyDirs = [
      vibeDurableMediaCacheRoot().appendingPathComponent("voice-cache", isDirectory: true),
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("voice-cache", isDirectory: true),
    ].compactMap { $0 }
    var legacyCandidates: [URL] = []
    for dir in legacyDirs {
      for hash in [chatStableCacheHash(identity), chatStableCacheHash(remoteURL.absoluteString)] {
        for candidateExt in [ext, "m4a", "mp3", "aac"] {
          legacyCandidates.append(dir.appendingPathComponent(hash + "." + candidateExt))
        }
      }
    }
    if let existing = vault.cachedURL(
      for: identity, kind: .audio, legacyCandidates: legacyCandidates)
    {
      Self.voiceSlotCache[slotCacheKey] = existing
      return existing
    }
    // The promised destination is stable too — the vault records it, and a download for
    // this identity lands exactly here — so it is safe to remember before the bytes exist.
    let destination = vault.destinationURL(
      for: identity, kind: .audio, fileExtension: ext, displayName: nil)
    Self.voiceSlotCache[slotCacheKey] = destination
    return destination
  }

  /// True when `url` points inside our remote voice/music download cache. Used to
  /// distinguish a poisoned cached file (safe to evict + re-fetch) from a user's own
  /// local recording or an imported file we must never delete.
  private func isCachedVoiceFile(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    let path = url.standardizedFileURL.path
    let vaultAudio = VibeMediaVault.shared.directory(for: .audio).standardizedFileURL.path
    if path.hasPrefix(vaultAudio) { return true }
    let durable = vibeDurableMediaCacheRoot()
      .appendingPathComponent("voice-cache", isDirectory: true)
      .standardizedFileURL.path
    if url.standardizedFileURL.path.hasPrefix(durable) { return true }
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    if let cacheDir = caches?.appendingPathComponent("voice-cache", isDirectory: true) {
      if url.standardizedFileURL.path.hasPrefix(cacheDir.standardizedFileURL.path) {
        return true
      }
    }
    return url.deletingLastPathComponent().lastPathComponent == "voice-cache"
  }

  private func importedLocalAudioURL(for sourceURL: URL) -> URL? {
    let normalizedURL = sourceURL.standardizedFileURL
    let normalizedPath = normalizedURL.path
    let homePath = NSHomeDirectory()
    if normalizedPath == homePath || normalizedPath.hasPrefix(homePath + "/") {
      return normalizedURL
    }

    let fileManager = FileManager.default
    let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
    let importDir = caches.appendingPathComponent("voice-local-imports", isDirectory: true)
    try? fileManager.createDirectory(at: importDir, withIntermediateDirectories: true)

    let sourceName = normalizedURL.deletingPathExtension().lastPathComponent
    let safeBase =
      (sourceName.isEmpty ? "audio" : sourceName)
      .replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
    let ext = normalizedURL.pathExtension.isEmpty ? "m4a" : normalizedURL.pathExtension
    let hashComponent = chatStableCacheHash(normalizedURL.absoluteString)
    let destinationURL = importDir
      .appendingPathComponent("\(safeBase)-\(hashComponent)", isDirectory: false)
      .appendingPathExtension(ext)

    if fileManager.fileExists(atPath: destinationURL.path) {
      return destinationURL
    }

    let didAccessScopedResource = normalizedURL.startAccessingSecurityScopedResource()
    defer {
      if didAccessScopedResource {
        normalizedURL.stopAccessingSecurityScopedResource()
      }
    }

    var coordinationError: NSError?
    var copyError: Error?
    let coordinator = NSFileCoordinator()
    coordinator.coordinate(readingItemAt: normalizedURL, options: [], error: &coordinationError) {
      readableURL in
      do {
        if fileManager.fileExists(atPath: destinationURL.path) {
          try fileManager.removeItem(at: destinationURL)
        }
        do {
          try fileManager.copyItem(at: readableURL, to: destinationURL)
        } catch {
          let data = try Data(contentsOf: readableURL, options: [.mappedIfSafe])
          try data.write(to: destinationURL, options: [.atomic])
        }
      } catch {
        copyError = error
      }
    }

    if let copyError {
      NSLog(
        "[ChatListView] voice local import failed source=%@ error=%@",
        normalizedURL.path,
        copyError.localizedDescription
      )
    } else if let coordinationError {
      NSLog(
        "[ChatListView] voice local import coordination failed source=%@ error=%@",
        normalizedURL.path,
        coordinationError.localizedDescription
      )
    }

    return fileManager.fileExists(atPath: destinationURL.path) ? destinationURL : normalizedURL
  }

  private func resolveAudioURL(from raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // Relative API media paths (e.g. `/api/music/stream/sc_…`) must NOT be treated as
    // local filesystem paths — that produced "Couldn't load" for server-sent music.
    if let absoluteAPI = Self.absoluteAPIURL(fromRelativeOrAbsolute: trimmed) {
      let cachedURL = cachedRemoteVoiceURL(for: absoluteAPI, fileName: activeFileName)
      if FileManager.default.fileExists(atPath: cachedURL.path) {
        return cachedURL
      }
      return absoluteAPI
    }

    // Sandbox path remapping: App UUIDs change on update/build, breaking absolute paths.
    var pathString = trimmed
    if trimmed.hasPrefix("file://") {
      let encoded =
        trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
      if let url = URL(string: trimmed) ?? URL(string: encoded) {
        pathString = url.path
      } else {
        pathString =
          String(trimmed.dropFirst(7)).removingPercentEncoding ?? String(trimmed.dropFirst(7))
      }
    }

    if pathString.contains("/Application/") || pathString.contains("/Containers/") {
      let sandboxTargets = ["/Library/", "/Documents/", "/tmp/"]
      for target in sandboxTargets {
        if let range = pathString.range(of: target, options: .backwards) {
          let suffix = pathString[range.lowerBound...]
          let patchedPath = NSHomeDirectory() + suffix
          // Once per distinct path. This resolves on every cell configure, so a voice
          // send was dumping four identical NSLog lines per settle — into the exact
          // main-thread beat the send already stalls on (measured setRows 54ms,
          // applyMs=47), which is part of why adding a voice note doesn't feel smooth.
          if patchedPath != Self.lastVoicePathRemapLogged {
            Self.lastVoicePathRemapLogged = patchedPath
            NSLog(
              "[ChatListView] voice path remap original=%@ patched=%@",
              shortMediaURL(raw),
              patchedPath
            )
          }
          return importedLocalAudioURL(for: URL(fileURLWithPath: patchedPath))
        }
      }
    }

    if let url = URL(string: trimmed), url.isFileURL {
      return importedLocalAudioURL(for: url)
    }
    // Only treat leading "/" as a local file when it is NOT an API path.
    if trimmed.hasPrefix("/"), !trimmed.hasPrefix("/api/") {
      return importedLocalAudioURL(for: URL(fileURLWithPath: trimmed))
    }
    if let decoded = trimmed.removingPercentEncoding,
      decoded.hasPrefix("/"),
      !decoded.hasPrefix("/api/")
    {
      return importedLocalAudioURL(for: URL(fileURLWithPath: decoded))
    }
    if let url = URL(string: trimmed), let scheme = url.scheme,
      scheme == "http" || scheme == "https"
    {
      let cachedURL = cachedRemoteVoiceURL(for: url, fileName: activeFileName)
      if FileManager.default.fileExists(atPath: cachedURL.path) {
        return cachedURL
      }
      return url
    }
    if let url = URL(string: trimmed), url.scheme == nil, !trimmed.hasPrefix("/api/") {
      return URL(fileURLWithPath: trimmed)
    }
    return nil
  }

  /// Join relative `/api/...` media paths onto the session API base (or production host).
  private static func absoluteAPIURL(fromRelativeOrAbsolute raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    {
      return url
    }

    // Relative API path from server when PUBLIC_BASE_URL was unset.
    let path: String
    if trimmed.hasPrefix("/api/") {
      path = trimmed
    } else if trimmed.hasPrefix("api/") {
      path = "/" + trimmed
    } else if trimmed.contains("/api/music/stream/") {
      // Path-only or host-less fragments
      if let range = trimmed.range(of: "/api/") {
        path = String(trimmed[range.lowerBound...])
      } else {
        return nil
      }
    } else {
      return nil
    }

    var base =
      AppSessionConfig.current?.apiBaseURLString
      ?? (ChatEngineStore.shared.getConfig()["apiBaseUrl"] as? String)
      ?? (ChatEngineStore.shared.getConfig()["baseUrl"] as? String)
      ?? "https://api.vibegram.io"
    base = base.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    // path already includes `/api/...`
    if base.lowercased().hasSuffix("/api"), path.hasPrefix("/api/") {
      base = String(base.dropLast(4))
    }
    return URL(string: base + path)
  }

  private func shortMediaURL(_ raw: String?) -> String {
    guard let raw, !raw.isEmpty else { return "-" }
    if raw.count <= 120 { return raw }
    return String(raw.prefix(117)) + "..."
  }

  private func publishSnapshot(forceNowPlaying: Bool = false) {
    // The banner is gated on real playback: latch the first time audio is actually
    // playing so downloading / resolving / broken taps never surface the pill.
    if isPlaying { bannerPlaybackStarted = true }
    let snapshot: VoiceBubblePlaybackSnapshot
    if let activeMessageId {
      let duration = currentPlaybackDuration()
      let downloading = activeDownloadTask != nil
      snapshot = VoiceBubblePlaybackSnapshot(
        messageId: activeMessageId,
        chatId: activeChatId,
        isPlaying: isPlaying,
        progress: playbackProgress,
        duration: duration,
        playbackRate: playbackRate,
        queueOrderMode: queueOrderMode,
        isRepeatEnabled: isRepeatEnabled,
        isDownloading: downloading,
        downloadProgress: downloading ? activeDownloadProgress : nil,
        downloadFraction: downloading ? activeDownloadProgress : nil,
        downloadedBytes: downloading ? activeDownloadedBytes : nil,
        totalBytes: downloading ? activeTotalBytes : nil,
        title: activeTitle,
        subtitle: activeSubtitle,
        artwork: activeArtwork,
        presentsGlobalPlayer: presentsGlobalPlayer && bannerPlaybackStarted
      )
    } else {
      snapshot = .empty
    }
    currentSnapshot = snapshot
    syncSystemPlaybackState(forceNowPlaying: forceNowPlaying)

    // The display link publishes at the screen refresh rate — 120Hz on ProMotion — and every
    // post fans out to the now-playing banner and to a sweep of every visible cell. That is
    // the whole budget of a scroll frame spent re-deciding things that did not change, which
    // is why scrolling stuttered whenever audio was playing.
    //
    // The bubble that owns the waveform is driven DIRECTLY by the tick (`activeCell?.
    // applyVoicePlaybackState`), so it stays frame-smooth regardless. Observers only need
    // this when something semantic flips — and a slow tick for the elapsed-time readout.
    let semanticSignature = [
      snapshot.messageId ?? "-",
      snapshot.chatId ?? "-",
      snapshot.isPlaying ? "1" : "0",
      snapshot.isDownloading ? "1" : "0",
      snapshot.presentsGlobalPlayer ? "1" : "0",
      snapshot.isRepeatEnabled ? "1" : "0",
      String(format: "%.2f", snapshot.playbackRate),
      snapshot.title ?? "-",
      snapshot.subtitle ?? "-",
    ].joined(separator: "|")
    let now = ProcessInfo.processInfo.systemUptime
    let semanticChanged = semanticSignature != lastPublishedSemanticSignature
    if !forceNowPlaying, !semanticChanged,
      now - lastSnapshotPublishAt < Self.progressPublishInterval
    {
      return
    }
    lastPublishedSemanticSignature = semanticSignature
    lastSnapshotPublishAt = now
    NotificationCenter.default.post(name: .voiceBubblePlaybackDidChange, object: self)
  }

  /// Progress-only republish cadence. Fast enough that the banner's elapsed readout and the
  /// download ring look live, slow enough to be invisible in a scroll frame budget.
  private static let progressPublishInterval: Double = 0.1
}

private final class MessageSelectionCircleView: UIControl {
  private var checked = false
  private var accentColor = ChatListAppearance.current.accent
  private let ringLayer = CAShapeLayer()
  private let fillLayer = CAShapeLayer()
  private let checkLayer = CAShapeLayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isHidden = true
    isAccessibilityElement = true
    accessibilityLabel = "Select message"
    isOpaque = false

    ringLayer.fillColor = UIColor.clear.cgColor
    ringLayer.strokeColor = UIColor.secondaryLabel.withAlphaComponent(0.56).cgColor
    ringLayer.lineWidth = 2.0
    layer.addSublayer(ringLayer)

    fillLayer.fillColor = accentColor.cgColor
    fillLayer.opacity = 0
    fillLayer.transform = CATransform3DMakeScale(0.55, 0.55, 1)
    layer.addSublayer(fillLayer)

    checkLayer.fillColor = UIColor.clear.cgColor
    checkLayer.strokeColor = UIColor.white.cgColor
    checkLayer.lineWidth = 2.0
    checkLayer.lineCap = .round
    checkLayer.lineJoin = .round
    checkLayer.opacity = 0
    checkLayer.strokeEnd = 0
    layer.addSublayer(checkLayer)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(selected: Bool, appearance: ChatListAppearance, animated: Bool = true) {
    accentColor = appearance.accent
    fillLayer.fillColor = accentColor.cgColor
    accessibilityValue = selected ? "Selected" : "Not selected"
    let changed = checked != selected
    checked = selected
    applyCheckedState(animated: animated && changed && window != nil)
  }

  /// Fade/scale the circle in when selection mode begins (or out when it ends).
  func setSelectionChromeVisible(_ visible: Bool, animated: Bool) {
    let target: CGFloat = visible ? 1 : 0
    let scale: CGFloat = visible ? 1 : 0.72
    if animated && window != nil {
      UIView.animate(
        withDuration: 0.28,
        delay: 0,
        usingSpringWithDamping: 0.84,
        initialSpringVelocity: 0.2,
        options: [.beginFromCurrentState, .allowUserInteraction]
      ) {
        self.alpha = target
        self.transform = visible ? .identity : CGAffineTransform(scaleX: scale, y: scale)
      } completion: { _ in
        self.isHidden = !visible
        if visible {
          self.transform = .identity
        }
      }
    } else {
      layer.removeAllAnimations()
      alpha = target
      transform = .identity
      isHidden = !visible
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let diameter = min(bounds.width, bounds.height) - 4.0
    guard diameter > 1.0 else { return }
    let circleRect = CGRect(
      x: (bounds.width - diameter) * 0.5,
      y: (bounds.height - diameter) * 0.5,
      width: diameter,
      height: diameter
    )
    let circlePath = UIBezierPath(ovalIn: circleRect).cgPath
    ringLayer.frame = bounds
    fillLayer.frame = bounds
    checkLayer.frame = bounds
    ringLayer.path = circlePath
    fillLayer.path = circlePath

    let check = UIBezierPath()
    check.move(to: CGPoint(x: circleRect.minX + diameter * 0.28, y: circleRect.midY + diameter * 0.03))
    check.addLine(to: CGPoint(x: circleRect.minX + diameter * 0.43, y: circleRect.midY + diameter * 0.22))
    check.addLine(to: CGPoint(x: circleRect.minX + diameter * 0.72, y: circleRect.midY - diameter * 0.24))
    checkLayer.path = check.cgPath
  }

  private func applyCheckedState(animated: Bool) {
    let fillOpacity: Float = checked ? 1 : 0
    let checkOpacity: Float = checked ? 1 : 0
    let checkEnd: CGFloat = checked ? 1 : 0
    let fillScale: CGFloat = checked ? 1 : 0.55
    let ringOpacity: Float = checked ? 0 : 1

    if animated {
      CATransaction.begin()
      CATransaction.setAnimationDuration(0.28)
      CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))

      fillLayer.opacity = fillOpacity
      fillLayer.transform = CATransform3DMakeScale(fillScale, fillScale, 1)
      checkLayer.opacity = checkOpacity
      checkLayer.strokeEnd = checkEnd
      ringLayer.opacity = ringOpacity
      CATransaction.commit()
    } else {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      fillLayer.opacity = fillOpacity
      fillLayer.transform = CATransform3DMakeScale(fillScale, fillScale, 1)
      checkLayer.opacity = checkOpacity
      checkLayer.strokeEnd = checkEnd
      ringLayer.opacity = ringOpacity
      CATransaction.commit()
    }
  }
}

/// Telegram-style forward attribution inside the bubble plate:
/// ```
/// Forwarded from
/// [avatar] Name
/// ```
/// Fixed height so list measurement and cell layout stay aligned (no content overlap).
private final class ForwardedFromHeaderView: UIView {
  /// Total strip height inside the bubble plate. Must match
  /// `ChatListView.forwardedHeaderHeight` exactly so size ↔ layout never drift.
  /// Telegram-tight: caption + avatar row with minimal padding.
  static let preferredHeight: CGFloat = 36.0
  private static let avatarSize: CGFloat = 18.0

  private let captionLabel = UILabel()
  /// Same global avatar renderer as Home / chat headers / group sender runs.
  private let avatarNode = ChatAvatarNodeView()
  private let nameLabel = UILabel()
  private var configuredName = ""
  private var configuredAvatarURL: String?
  private var configuredPeerUserId: String?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    clipsToBounds = true

    captionLabel.numberOfLines = 1
    captionLabel.font = .systemFont(ofSize: 12.0, weight: .regular)
    captionLabel.lineBreakMode = .byTruncatingTail
    addSubview(captionLabel)

    avatarNode.isUserInteractionEnabled = false
    addSubview(avatarNode)

    nameLabel.numberOfLines = 1
    nameLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
    nameLabel.lineBreakMode = .byTruncatingTail
    addSubview(nameLabel)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// Text uses the same me/them body color as the bubble (white or dark), not accent green.
  func configure(
    name: String,
    avatarURL: String?,
    peerUserId: String?,
    textColor: UIColor,
    isDark: Bool
  ) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = trimmed.isEmpty ? "Unknown" : trimmed
    captionLabel.text = "Forwarded from"
    captionLabel.textColor = textColor.withAlphaComponent(0.72)
    nameLabel.text = displayName
    nameLabel.textColor = textColor

    let url: String? = {
      guard let raw = avatarURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
      else { return nil }
      return raw
    }()
    let peer: String? = {
      guard let raw = peerUserId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
      else { return nil }
      return raw
    }()
    let unchanged =
      configuredName == displayName
      && configuredAvatarURL == url
      && configuredPeerUserId == peer
    if !unchanged {
      configuredName = displayName
      configuredAvatarURL = url
      configuredPeerUserId = peer
      avatarNode.configure(
        with: ChatAvatarDescriptor(
          title: displayName,
          rawAvatarURI: url,
          peerUserId: peer,
          chatId: nil,
          kind: .standard,
          isGroup: false,
          members: [],
          preferPushAvatar: false,
          gradientColors: nil
        ),
        isDark: isDark,
        renderingSide: Self.avatarSize
      )
    }
    setNeedsLayout()
  }

  func prepareForReuse() {
    configuredName = ""
    configuredAvatarURL = nil
    configuredPeerUserId = nil
    captionLabel.text = nil
    nameLabel.text = nil
    // Reconfigure with empty descriptor so a recycled cell never keeps a prior face.
    avatarNode.configure(
      with: ChatAvatarDescriptor(
        title: "",
        rawAvatarURI: nil,
        peerUserId: nil,
        chatId: nil,
        kind: .standard,
        isGroup: false,
        members: [],
        preferPushAvatar: false,
        gradientColors: nil
      ),
      isDark: traitCollection.userInterfaceStyle == .dark,
      renderingSide: Self.avatarSize
    )
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let w = bounds.width
    guard w > 1 else { return }
    // Telegram-tight stack: caption then avatar+name with minimal gap to body.
    captionLabel.frame = CGRect(x: 0, y: 0, width: w, height: 14)
    let rowY: CGFloat = 15
    avatarNode.frame = CGRect(
      x: 0, y: rowY, width: Self.avatarSize, height: Self.avatarSize)
    let nameX = Self.avatarSize + 6
    nameLabel.frame = CGRect(
      x: nameX,
      y: rowY,
      width: max(0, w - nameX),
      height: Self.avatarSize
    )
  }
}

final class ChatListCell: UICollectionViewCell, VoicePlayableCell {
  static let reuseIdentifier = "ChatListCell"

  private static var hasPrewarmedRealization = false

  /// Builds and discards a few cells at launch so the first open pays neither class
  /// realization nor first-time subview setup: cold dequeue measured 12.6ms, warm 2.7ms.
  static func prewarmRealization() {
    guard Thread.isMainThread, !hasPrewarmedRealization else { return }
    hasPrewarmedRealization = true
    let frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 80)
    for _ in 0..<3 { _ = ChatListCell(frame: frame) }
  }

  private static let reactionBadgeInsetLeft: CGFloat = 8.0
  private static let reactionBadgeInsetBottom: CGFloat = reactionStripBottomInset

  /// Authoritative chat id stamped by the list at configure time. Per-message payloads often
  /// omit `chat_id` (so `row.chatId` is nil for music), so this is the fallback used to key
  /// music playback + the player-sheet list on the chat that actually owns the message.
  var hostChatId: String = ""

  /// Stopwatch marks for the phase that turned out to dominate a chat open, and that no
  /// previous census could see.
  ///
  /// Swift runs every stored-property initializer BEFORE `super.init` returns, so a timer
  /// started at the top of `init(frame:)` has already missed the construction of all ~90
  /// subviews. That is why the section census read 1.2ms while `dequeueReusableCell`
  /// measured 5-6ms per row on device (`[CellCost] cellForItem … dequeue=5.5`): the
  /// missing 4ms is spent before the initializer body starts.
  ///
  /// Declaration order is the execution order, so a `let` placed between two groups of
  /// properties times the group above it. These are four `systemUptime` reads per cell and
  /// they answer the only open question left about mount cost: which cluster to make lazy.
  private let clkPropertiesBegan = ProcessInfo.processInfo.systemUptime

  let bubbleView = BubbleBackgroundView()
  let tailView = BubbleTailView()

  /// Group/channel sender name, shown above the FIRST bubble of an incoming sender-run
  /// (Telegram-style), tinted with the sender's colour (Claude ≈ orange, Codex ≈ white).
  private let groupSenderNameLabel = UILabel()
  /// Telegram-style forward strip (caption + avatar + name) inside the plate top.
  private let forwardedFromHeader = ForwardedFromHeaderView()
  /// Leading avatar-gutter width the view asked us to reserve for incoming group bubbles
  /// (0 for DMs and outgoing). Narrows the bubble + shifts it right so the floating avatar
  /// overlay has a column; kept in sync with the height measurement in `sizeForItemAt`.
  private var groupExtraLeading: CGFloat = 0.0
  /// Reserved top space for the name label when it is shown (0 otherwise).
  private var groupNameReservedHeight: CGFloat = 0.0
  /// Empty air before a sender run. This is separate from the name strip because the
  /// name belongs inside the plate while the run gap belongs on the wallpaper.
  private var groupTopReservedSpacing: CGFloat = 0.0
  /// Banner palette for the compact quoted-reply preview only (never the whole bubble).
  private var replyAccentColors: (UIColor, UIColor)?

  private let messageLabel = AgentStreamingLabel()
  // The real interleaved step/narration/diff renderer, bubble-shelled — the live content
  // for a 1:1 agent turn (see bubbleUsesAgentTurnContent).
  /// Built the first time an agent turn is rendered — see ``agentTurnContentView``.
  private var _agentTurnContentView: VibeAgentTurnContentView?
  /// The interleaved step/narration/diff panel for a 1:1 agent turn. 462us to construct,
  /// and the most expensive single thing in the cell after the text view.
  ///
  /// It is used only by agent turns, which in a human conversation is none of the rows,
  /// so building one per cell was the largest pure waste in the mount. Same rule as
  /// ``agentActionBarView``: reads through `_agentTurnContentView?` wherever the intent is
  /// to hide, reset, measure-if-present or animate-if-present, and through this property
  /// only where the panel is genuinely about to render.
  private var agentTurnContentView: VibeAgentTurnContentView {
    if let existing = _agentTurnContentView { return existing }
    let view = VibeAgentTurnContentView()
    view.clipsToBounds = true
    view.onStepTap = { [weak self] nodeId in
      guard let self, let row = self.row, let messageId = row.messageId else { return }
      self.onAgentAction?(["type": "toggleAgentStep", "messageId": messageId, "nodeId": nodeId])
    }
    view.onOpenSubagent = { [weak self] nodeId in
      guard let self, let row = self.row, let messageId = row.messageId else { return }
      self.onAgentAction?(["type": "openAgentSubagent", "messageId": messageId, "nodeId": nodeId])
    }
    view.onToggleRuntimeExpand = { [weak self] in
      guard let self, let row = self.row, let messageId = row.messageId else { return }
      self.onAgentAction?(["type": "toggleAgentRuntime", "messageId": messageId])
    }
    view.onReviewTapped = { [weak self] in
      guard let self, let row = self.row, let messageId = row.messageId else { return }
      self.onAgentAction?(["type": "agentReviewTapped", "messageId": messageId])
    }
    view.onFileTapped = { [weak self] _ in
      guard let self, let row = self.row, let messageId = row.messageId else { return }
      self.onAgentAction?(["type": "agentReviewTapped", "messageId": messageId])
    }
    // Above the plain text label and below the media host, which is where the eager
    // version sat in the initializer's subview order.
    contentView.insertSubview(view, aboveSubview: messageLabel)
    _agentTurnContentView = view
    return view
  }
  /// Built the first time a turn shows a live computer — same lazy contract as above.
  private var _agentComputerBandView: AgentComputerBandView?
  private var agentComputerBandView: AgentComputerBandView {
    if let existing = _agentComputerBandView { return existing }
    let view = AgentComputerBandView()
    view.addTarget(self, action: #selector(agentComputerBandTapped), for: .touchUpInside)
    contentView.insertSubview(view, aboveSubview: agentTurnContentView)
    _agentComputerBandView = view
    return view
  }
  /// Built the first time a decision row shows a risk chip / detail block.
  private var _serviceDecisionCardView: ChatServiceDecisionCardView?
  private var serviceDecisionCardView: ChatServiceDecisionCardView {
    if let existing = _serviceDecisionCardView { return existing }
    let view = ChatServiceDecisionCardView()
    contentView.insertSubview(view, belowSubview: serviceActionBarView)
    _serviceDecisionCardView = view
    return view
  }
  private var agentTurnState = AgentTurnBubbleState()
  // Reconfigure gate for agentTurnContentView: `layoutSubviews` runs on every scroll
  // tick / pin adjustment, but `configure(row:)` re-parses the FULL progress payload
  // (all nodes) and rebuilds the body — far too heavy per layout pass on a large turn.
  // Remember what the body was last configured with and skip the reconfigure when
  // nothing it renders from has changed; frames are still (re)applied every pass.
  private var lastAgentTurnConfiguredRow: ChatListRow?
  private var lastAgentTurnConfiguredWidth: CGFloat = -1.0
  private var lastAgentTurnConfiguredState: AgentTurnBubbleState?
  private var lastAgentTurnConfiguredStyle: UIUserInterfaceStyle = .unspecified
  private let richTextView = BubbleRichTextView()
  private let replyPreviewView = BubbleReplyPreviewView()
  /// Built the first time a row carries a link preview — see ``linkPreviewView``.
  private var _linkPreviewView: BubbleLinkPreviewView?
  private var lastTouchPointInCell: CGPoint?
  private var lastTouchAt: TimeInterval = 0
  /// The link-preview card. 156us to construct, needed by the rare message that has a URL.
  ///
  /// Same contract as ``agentTurnContentView`` and ``agentActionBarView``: hiding,
  /// resetting, zeroing a frame and reading visibility all go through
  /// `_linkPreviewView?`; only rendering a preview goes through this.
  private var linkPreviewView: BubbleLinkPreviewView {
    if let existing = _linkPreviewView { return existing }
    let view = BubbleLinkPreviewView()
    view.onPreviewAvailabilityChange = { [weak self] in
      self?.setNeedsLayout()
    }
    view.applyAppearance(appearance, isMe: row?.isMe ?? false)
    // Directly above the reply preview, matching the eager initializer's subview order.
    contentView.insertSubview(view, aboveSubview: replyPreviewView)
    _linkPreviewView = view
    return view
  }
  /// Everything above: bubble plate, tail, text/rich-text, reply + link previews.
  private let clkPropsAfterBubble = ProcessInfo.processInfo.systemUptime
  private let mediaContainerView = UIView()
  /// Built the first time a row actually needs the transfer scrim — see
  /// ``mediaPlaceholderBlurView``. The tint lives inside the blur's `contentView` and has
  /// no independent existence, so the two are created together and share one backing.
  private var _mediaPlaceholderBlurView: UIVisualEffectView?
  private var _mediaPlaceholderTintView: UIView?
  private var _viewOnceShineCover: ChatViewOnceShineCoverView?
  /// The soft material scrim over a still preview while its media transfers.
  ///
  /// Same contract as ``linkPreviewView``: hiding, resetting, zeroing a frame, reading
  /// visibility and re-tinting all go through `_mediaPlaceholderBlurView?` /
  /// `_mediaPlaceholderTintView?`; only actually SHOWING a scrim goes through this.
  ///
  /// `UIVisualEffectView` is one of the three types every cell used to pay for whether or
  /// not it had media — the census at ``logConstructionCostCensus`` measured the whole
  /// cell at 12-17ms, and a plain text bubble bought a blur, an `AVPlayerLayer` and a
  /// Lottie view it could never show. Device export 2026-08-06: `layout=63..170ms` for a
  /// 64-row seed, against 2ms for all of `ChatTimelineLayout`. The geometry was never the
  /// cost; constructing ~12 of these was.
  private var mediaPlaceholderBlurView: UIVisualEffectView {
    if let existing = _mediaPlaceholderBlurView { return existing }
    let view = UIVisualEffectView(
      effect: UIBlurEffect(
        style: appearance.isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight))
    view.clipsToBounds = true
    view.isHidden = true
    let tint = UIView()
    tint.backgroundColor = UIColor(
      white: appearance.isDark ? 0.02 : 0.98,
      alpha: appearance.isDark ? 0.18 : 0.10
    )
    view.contentView.addSubview(tint)
    // Directly above the video host, matching the eager initializer's subview order:
    // image → video host → scrim → sticker → chrome. Anchoring to `mediaVideoPlayerHostView`
    // rather than to the sticker keeps this correct whichever of the two lazy views was
    // built first — asking for the sticker here would construct the thing being avoided.
    mediaContainerView.insertSubview(view, aboveSubview: mediaVideoPlayerHostView)
    _mediaPlaceholderBlurView = view
    _mediaPlaceholderTintView = tint
    // Frames are assigned in `layoutSubviews`, which has not run for this view yet.
    setNeedsLayout()
    return view
  }

  private var viewOnceShineCover: ChatViewOnceShineCoverView {
    if let existing = _viewOnceShineCover { return existing }
    let view = ChatViewOnceShineCoverView()
    view.isHidden = true
    mediaContainerView.insertSubview(view, belowSubview: mediaPrimaryIconView)
    _viewOnceShineCover = view
    return view
  }

  private func shouldShowViewOnceShineCover(_ row: ChatListRow) -> Bool {
    guard row.viewOnce, !isGhostHidden, row.messageType != "file" else { return false }
    switch row.visualKind {
    case .media, .video:
      return true
    case .videoNote:
      return !agentTurnState.videoNoteExpanded
    default:
      return false
    }
  }

  private func refreshViewOnceShineCover() {
    guard let row, shouldShowViewOnceShineCover(row) else {
      _viewOnceShineCover?.setActive(false)
      _viewOnceShineCover?.isHidden = true
      return
    }
    let cover = viewOnceShineCover
    cover.isHidden = false
    let key = row.messageId ?? row.key
    let sealed = chatViewOnceSealedImage(key: key)
    if let sealed {
      let concealed = chatViewOnceConcealedStill(from: sealed, cacheKey: key)
      mediaImageView.image = concealed
      mediaImageView.isHidden = false
    }
    cover.apply(
      image: sealed,
      cacheKey: key,
      count: 1,
      circular: row.visualKind == .videoNote,
      timerSeconds: row.mediaTtlSeconds)
    cover.setActive(window != nil)
  }
  /// The tint plate inside the scrim. Reaching for it builds the scrim, because it cannot
  /// exist without one.
  private var mediaPlaceholderTintView: UIView {
    _ = mediaPlaceholderBlurView
    return _mediaPlaceholderTintView ?? UIView()
  }
  private let mediaImageView = UIImageView()
  /// Quality of pixels currently in `mediaImageView` — enforces promote-only replaces.
  private var mediaPixelQuality: ChatMediaPreviewQuality = .none
  private let mediaVideoPlayerHostView = UIView()
  /// Built the first time a row renders an animated sticker — see
  /// ``mediaStickerAnimationView``.
  private var _mediaStickerAnimationView: LottieAnimationView?
  /// The Lottie surface for animated stickers.
  ///
  /// Same contract as ``mediaPlaceholderBlurView``: stopping, clearing, hiding, zeroing a
  /// frame and reading `isHidden` / `isAnimationPlaying` all go through
  /// `_mediaStickerAnimationView?`; only mounting an animation goes through this.
  private var mediaStickerAnimationView: LottieAnimationView {
    if let existing = _mediaStickerAnimationView { return existing }
    let view = LottieAnimationView()
    view.backgroundColor = .clear
    view.contentMode = .scaleAspectFit
    view.loopMode = .loop
    view.backgroundBehavior = .pauseAndRestore
    view.isUserInteractionEnabled = false
    view.isHidden = true
    // Directly below the media chrome, matching the eager initializer's subview order.
    // Anchored to `mediaPrimaryIconView` (always eager) rather than to the scrim above it,
    // so building a sticker never drags a blur view into existence with it.
    mediaContainerView.insertSubview(view, belowSubview: mediaPrimaryIconView)
    _mediaStickerAnimationView = view
    setNeedsLayout()
    return view
  }
  private let mediaPrimaryIconView = UIImageView()
  private let mediaBorderLayer = CAShapeLayer()
  private let mediaVoiceButtonView = VoicePlayProgressView()
  private let mediaTitleLabel = UILabel()
  private let mediaDetailLabel = UILabel()
  private let mediaWaveformView = VoiceWaveformView()
  private let mediaVideoInfoBadgeView = UIView()
  private let mediaVideoTimeIconView = UIImageView()
  private let mediaVideoAudioIconView = UIImageView()
  private let mediaDurationBadge = UILabel()
  private let mediaProgressOverlayView = UIView()
  private let mediaProgressRingView = BubbleUploadProgressView()
  // Multi-image bridge sends: tile views for the inline grid (created lazily, max 6).
  /// Multi-image body — a swipeable deck (or inline carousel when the message has
  /// a caption). Replaces the tile grid; created lazily, see `ensureMediaStackView`.
  private var mediaStackView: ChatMediaStackView?
  private var mediaGridRowKey: String?
  private static let bridgeGridImageCache = NSCache<NSString, UIImage>()
  private static let bridgeGridDecodeQueue = DispatchQueue(
    label: "chat.media.grid-decode", qos: .userInitiated)
  /// Serial, so category and activation stay ordered while both stay off the main thread.
  private static let audioSessionQueue = DispatchQueue(
    label: "chat.media.audio-session", qos: .utility)
  private let mediaProgressSpinner = UIActivityIndicatorView(style: .medium)
  private let mediaProgressSizeLabel = UILabel()
  /// Everything above: the whole media cluster — image/video host, blur, Lottie, voice
  /// waveform, badges, progress ring, spinner. A text bubble uses none of it.
  private let clkPropsAfterMedia = ProcessInfo.processInfo.systemUptime
  private let inlineAttachmentView = UIView()
  private let inlineAttachmentIconView = UIImageView()
  private let inlineAttachmentTitleLabel = UILabel()
  private let inlineAttachmentSubtitleLabel = UILabel()
  let metaContainerView = UIView()
  private let editedLabel = UILabel()
  private let pinnedLabel = UILabel()
  private let viewIconView = UIImageView()
  private let viewCountLabel = ChatRollingCounterLabel()
  private let timestampLabel = UILabel()
  private let statusImageView = UIImageView()
  private let statusLabel = UILabel()
  private let pendingStatusView = ChatPendingStatusView()
  /// Everything above: inline attachment plate and the meta row (time, edited, pinned,
  /// status glyph).
  private let clkPropsAfterMeta = ProcessInfo.processInfo.systemUptime
  private let retryButton = UIButton(type: .system)
  private let agentRegenerateButton = UIButton(type: .system)
  // "View agent" side button on completed agent bubbles — opens the native
  // full-page agent surface (progress/thinking/tools) for that single task.
  private let agentViewButton = UIButton(type: .system)
  // Tall-collapse: glass expand/collapse chip is hosted by ChatListView (outside the
  // list cell). The cell only exposes an anchor via `tallToggleAnchor`.
  private var tallToggleRowMessageId: String?
  private var lastBubbleFrame: CGRect = .zero
  /// The bubble's last laid-out frame in CELL coordinates. Exposed read-only so the
  /// list can dump bubble-vs-cell geometry when diagnosing a visual overlap that the
  /// cell-frame logs (which only see cell heights) can't explain: the bubble is
  /// bottom-aligned and drawn UNCLIPPED, so a bubble taller than its cell spills into
  /// the neighbor even though the cell frames themselves don't overlap.
  var renderedBubbleFrameInCell: CGRect { lastBubbleFrame }
  private var lastTallToggleVisible = false
  private var lastTallCollapsed = false
  private var tallContentAnimationGeneration: UInt = 0
  private let notSentIndicator = UIImageView()
  private var notSentIndicatorShown = false
  /// Built the first time a row actually needs it — see ``agentActionBarView``.
  private var _agentActionBarView: ChatNativeAgentActionBarView?
  /// The action bar under an `agent_actions` row: 319us to construct, and needed by a
  /// vanishingly small fraction of messages.
  ///
  /// Every cell used to build one. In a thousand-row transcript of ordinary text that is
  /// 319ms spent on a control nobody will see, paid again on every mount. The three heavy
  /// optional subviews (this, the agent turn panel, the link preview) together account for
  /// ~940us of a ~3.6ms cell.
  ///
  /// The rule that makes laziness actually pay: **hiding must not build**. Touching this
  /// property creates the view, so every `isHidden = true` / reset path uses
  /// `_agentActionBarView?` instead. A single stray `agentActionBarView.isHidden = true`
  /// in a reset path would construct one for every cell and give back nothing.
  private var agentActionBarView: ChatNativeAgentActionBarView {
    if let existing = _agentActionBarView { return existing }
    let view = ChatNativeAgentActionBarView()
    view.onNativeEvent = { [weak self] payload in
      self?.onAgentAction?(payload)
    }
    contentView.addSubview(view)
    _agentActionBarView = view
    return view
  }
  private let serviceActionBarView = ChatServiceActionBarView()
  private let dayLabel = UILabel()
  private let reactionStripView = ChatReactionStripView()
  private let selectionCircleView = MessageSelectionCircleView()
  private var appearance = ChatListAppearance.current
  var row: ChatListRow?
  private var selectionMode = false
  private var isSelectionChecked = false
  private var isGhostHidden = false
  /// Whether the last configure() rendered this row as a centered agent system divider
  /// (interrupt / compaction) reusing `dayLabel` — lets `layoutSubviews` position it with
  /// the day-pill centering path instead of the bubble path.
  private var isConfiguredAgentDivider = false
  /// Service-notice divider that also shows live decision action chips under the pill.
  private var isConfiguredServiceDecision = false
  /// Whether the last configure() rendered this row as a centered agent *error* notice
  /// (a failed turn) reusing the `dayLabel` pill. Drives the warning tint + makes the
  /// pill tappable to retry.
  private var isConfiguredAgentErrorNotice = false
  /// Whether the last configure() hid this cell as the send-morph ghost — lets the
  /// host verify/repair the reveal after the transition without reconfiguring blindly.
  var isConfiguredGhostHidden: Bool { isGhostHidden }
  /// Compact visibility audit for the first-message morph handoff. A cell can be
  /// realized at the correct collection frame while one of its private body views is
  /// still hidden; logging only `cell.alpha`/`ghost` cannot distinguish that state.
  var sendMorphVisibilitySummary: String {
    String(
      format:
        "cell(h=%@ a=%.2f pa=%.2f) content(h=%@ a=%.2f pa=%.2f) bubble(h=%@ a=%.2f) text(h=%@ a=%.2f len=%d) tail(h=%@ a=%.2f) meta(h=%@ a=%.2f)",
      isHidden ? "Y" : "N", alpha, layer.presentation()?.opacity ?? layer.opacity,
      contentView.isHidden ? "Y" : "N", contentView.alpha,
      contentView.layer.presentation()?.opacity ?? contentView.layer.opacity,
      bubbleView.isHidden ? "Y" : "N", bubbleView.alpha,
      messageLabel.isHidden ? "Y" : "N", messageLabel.alpha,
      messageLabel.attributedText?.length ?? 0,
      tailView.isHidden ? "Y" : "N", tailView.alpha,
      metaContainerView.isHidden ? "Y" : "N", metaContainerView.alpha
    )
  }
  private var isContextMenuExtracted = false
  private var isContextMenuHeld = false
  private var savedBubbleHiddenBeforeExtraction = false
  private var savedTailHiddenBeforeExtraction = false
  private var savedReactionHiddenBeforeExtraction = false
  private var savedMessageAlphaBeforeExtraction: CGFloat = 1.0
  private var savedAgentTurnContentAlphaBeforeExtraction: CGFloat = 1.0
  private var savedRichTextAlphaBeforeExtraction: CGFloat = 1.0
  private var savedReplyPreviewAlphaBeforeExtraction: CGFloat = 1.0
  private var savedLinkPreviewAlphaBeforeExtraction: CGFloat = 1.0
  private var savedInlineAttachmentAlphaBeforeExtraction: CGFloat = 1.0
  private var savedMediaAlphaBeforeExtraction: CGFloat = 1.0
  private var savedMetaAlphaBeforeExtraction: CGFloat = 0.72
  private var hasSavedExtractionState = false
  private var cellHoldAnchorApplied = false
  private var contentViewHoldAnchorApplied = false
  private var externalVoiceMessageId: String?
  private var externalVoiceIsPlaying = false
  private var externalVoiceProgress: CGFloat = 0.0
  private var cachedLayoutMetrics: ChatMessageBubbleLayoutMetrics?
  private var cachedLayoutWidth: CGFloat = 0
  private var mediaImageTask: URLSessionDataTask?
  /// Cache key the in-flight fetch was started for; only a different key cancels it.
  private var mediaImageTaskKey: String?
  /// Cache key of the off-main decode in flight, so a reconfigure does not start a second.
  private var mediaDecodeInFlightKey: String?
  private var musicCoverTask: URLSessionDataTask?
  /// Built the first time a row plays inline video — see ``mediaVideoPlayerLayer``.
  private var _mediaVideoPlayerLayer: AVPlayerLayer?
  /// The inline video surface.
  ///
  /// Same contract as ``mediaStickerAnimationView``: detaching a player, zeroing opacity,
  /// sizing and reading `player` all go through `_mediaVideoPlayerLayer?`; only attaching
  /// a player goes through this. It is the only sublayer `mediaVideoPlayerHostView` ever
  /// gets, so there is no z-order to preserve.
  private var mediaVideoPlayerLayer: AVPlayerLayer {
    if let existing = _mediaVideoPlayerLayer { return existing }
    let layer = AVPlayerLayer()
    layer.videoGravity = .resizeAspectFill
    layer.opacity = 0.0
    layer.frame = mediaVideoPlayerHostView.bounds
    mediaVideoPlayerHostView.layer.addSublayer(layer)
    _mediaVideoPlayerLayer = layer
    return layer
  }
  private var mediaVideoPlayer: AVPlayer?
  private var mediaVideoLoopObserver: NSObjectProtocol?
  private var mediaVideoStatusObserver: NSKeyValueObservation?
  private var mediaVideoTimeObserver: Any?
  private var mediaVideoPlayerURLKey: String?
  /// Vault identity (or canonical file path) behind the player, so a local-url patch to the
  /// same bytes does not rebuild it.
  private var mediaVideoPlayerIdentityKey: String?
  /// Set by an explicit user play/unmute; only then does the audio session get configured.
  private var mediaVideoUserInitiatedPlay = false
  private var mediaVideoPlaybackActive = false
  private var mediaVideoHasCompletedOnce = false
  private var mediaVideoUserPaused = false
  private var mediaTransferChromeShown = false
  private var mediaVideoReady = false
  private var mediaVideoIsMuted = true
  private var mediaVideoHasAudio = false
  private var mediaVideoCurrentTime: Double = 0.0
  private var mediaVideoTotalDuration: Double?
  private var mediaNeedsDownload = false
  private var mediaIsDownloading = false
  private var mediaDownloadFailed = false
  private var mediaDownloadProgress: Double?
  private var mediaDownloadedBytes: Int64?
  private var mediaTotalDownloadBytes: Int64?
  private var documentPageCount: Int?
  private var documentByteSize: Int64?
  private var skipRemoteMediaLoad = false
  private var preferredLocalMediaURLOverride: String?
  private weak var wallpaperCoordinateView: UIView?
  private var wallpaperBackdropSnapshot: CGImage?
  private var wallpaperBackdropContainerSize: CGSize = .zero
  private var currentStickerAnimationKey: String?
  private let fullBleedMaskLayer = CAShapeLayer()
  private var lastReportedMediaSizeKey: String?
  private var lastReactionDebugSignature: String?
  private var renderedStatusKey: String?
  /// What the status slot currently DRAWS (`pending`/`single`/`double`/`error`), as
  /// opposed to the raw status. Several statuses map to the same glyph, so this is what
  /// decides whether a change is worth animating.
  private var renderedStatusGlyph: String?
  var resolveDisplayStatus: ((ChatListRow) -> String?)?
  var onVoiceBubbleTap: ((ChatListRow) -> Void)?
  var onVoiceUploadCancelTap: ((ChatListRow) -> Void)?
  var onInlineAttachmentTap: ((ChatListRow) -> Void)?
  var onMediaNaturalSizeResolved: ((String?, String, CGSize) -> Void)?
  /// Multi-image grid tile tapped — `(row, tileIndex, sourceImageView)`.
  var onMediaGridTileTap: ((ChatListRow, Int, UIImageView) -> Void)?
  var onRetryMessageTap: ((ChatListRow) -> Void)?
  var onNotSentTap: ((ChatListRow) -> Void)?
  /// Tapped the centered "Something went wrong · Try again" agent-error notice pill.
  var onAgentErrorRetryTap: ((ChatListRow) -> Void)?
  var onAgentAction: (([String: Any]) -> Void)?
  var onReactionHold: ((ChatListRow, String, CGPoint) -> Void)?
  var onReactionTap: ((ChatListRow, String) -> Void)?
  /// Claim a sender-declared decision action (opaque token).
  var onServiceDecisionAction: ((ChatListRow, ChatServiceAction) -> Void)?
  var onSelectionToggle: ((ChatListRow) -> Void)?
  /// This cell's slot does not match the bubble it renders — `(row key, slack)`, where
  /// slack is negative when the slot is too SHORT (inner content paints outside the
  /// plate) and positive when it is too TALL (the bubble is bottom-pinned, so the excess
  /// shows as empty air above it). The host drops that row's cached/persisted height and
  /// re-measures; see the report in `layoutSubviews`.
  var onSlotHeightMismatch: ((String, CGFloat) -> Void)?
  /// Everything above: buttons, action bars, day pill, reaction pill, selection circle,
  /// and the callback slots. Last stored property — `init(frame:)` starts after this.
  private let clkPropsEnded = ProcessInfo.processInfo.systemUptime

  /// One-shot construction cost census. Every subview below is a stored `let`, so a plain
  /// text bubble pays for a blur view, an AVPlayerLayer, a Lottie view and the whole
  /// agent-turn panel it will never show — measured at 12-17ms per cell, which is the
  /// reason the transcript cannot be mounted before the push. This prints what each type
  /// actually costs so the lazy-conversion targets the pieces that matter. Main thread.
  static func logConstructionCostCensus() {
    func timeUs(_ label: String, _ make: () -> Void) {
      let iterations = 10
      let startedAt = ProcessInfo.processInfo.systemUptime
      for _ in 0..<iterations { make() }
      let us = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000_000 / Double(iterations)
      NSLog("[CellCost] %@ %.0fus", label, us)
    }
    timeUs("ChatListCell(WHOLE)") { _ = ChatListCell(frame: .zero) }
    // The three every cell pays for unconditionally. `stored properties … bubble+text`
    // measures 2,489us on device while the optional views inside that same group add up
    // to ~660us, so ~1.8ms belongs to these — and none of them were in this census, which
    // is why the missing time looked like "multiplicity" rather than three named types.
    // A view that every message needs cannot be made lazy, so it has to be made cheaper,
    // and that starts with knowing which of the three it is.
    timeUs("BubbleBackgroundView") { _ = BubbleBackgroundView(frame: .zero) }
    timeUs("BubbleTailView") { _ = BubbleTailView() }
    timeUs("AgentStreamingLabel") { _ = AgentStreamingLabel() }
    timeUs("VibeAgentTurnContentView") { _ = VibeAgentTurnContentView() }
    timeUs("UIVisualEffectView(blur)") {
      _ = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    }
    timeUs("AVPlayerLayer") { _ = AVPlayerLayer() }
    timeUs("LottieAnimationView") { _ = LottieAnimationView() }
    timeUs("BubbleRichTextView") { _ = BubbleRichTextView() }
    timeUs("BubbleLinkPreviewView") { _ = BubbleLinkPreviewView() }
    timeUs("BubbleReplyPreviewView") { _ = BubbleReplyPreviewView() }
    timeUs("VoiceWaveformView") { _ = VoiceWaveformView() }
    timeUs("ChatNativeAgentActionBarView") { _ = ChatNativeAgentActionBarView() }
    timeUs("BubbleUploadProgressView") { _ = BubbleUploadProgressView() }
    timeUs("MessageSelectionCircleView") { _ = MessageSelectionCircleView() }
    timeUs("ForwardedFromHeaderView") { _ = ForwardedFromHeaderView() }
    timeUs("ChatPendingStatusView") { _ = ChatPendingStatusView() }
    timeUs("UILabel") { _ = UILabel() }
  }

  /// Per-section cost of building one cell, averaged over the first `initCensusSamples`
  /// cells and printed once.
  ///
  /// `logConstructionCostCensus` times each subview *type* once, which cannot explain the
  /// total: the whole cell measures ~8,700us while every type it names adds up to ~1,300.
  /// The missing 7ms is multiplicity — dozens of labels, image views and containers, and
  /// 73 `addSubview` calls — and a per-type census is structurally unable to attribute it.
  /// Lazy conversion has to know which *cluster* to start with, so this measures the
  /// clusters as the initializer actually builds them.
  ///
  /// The stamps cost four `systemUptime` reads on the first 20 cells and nothing after.
  /// Cells this process has constructed, ever.
  ///
  /// The scroll profile reads this at both ends of a gesture to answer the one question
  /// a dropped-frame count cannot: was the reuse pool COLD? A device run measured
  /// `dequeue=4.0…5.0ms` while cells were being built and `0.5…0.7ms` once the pool had
  /// filled, so "24 built during this fling" and "0 built during this fling" are two
  /// completely different bugs wearing the same 9%-dropped line.
  ///
  /// One integer increment per cell. It is not gated on a debug flag because the whole
  /// point is to have the number on the run where the reader says it felt bad.
  static private(set) var constructionCount = 0

  private static var initCensusSamples = 0
  private static var initCensusBase: Double = 0
  private static var initCensusMedia: Double = 0
  private static var initCensusAttachmentMeta: Double = 0
  private static var initCensusAgent: Double = 0
  // The stored-property phase, which runs before `init(frame:)` and is where the missing
  // milliseconds actually are. Same four groups, timed by the `clkProps*` marks.
  private static var propCensusBubble: Double = 0
  private static var propCensusMedia: Double = 0
  private static var propCensusMeta: Double = 0
  private static var propCensusRest: Double = 0
  private static var propCensusSuperInit: Double = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    Self.constructionCount &+= 1
    let censusActive = Self.initCensusSamples < 20
    let t0 = censusActive ? ProcessInfo.processInfo.systemUptime : 0

    clipsToBounds = false
    contentView.clipsToBounds = false
    automaticallyUpdatesContentConfiguration = false
    automaticallyUpdatesBackgroundConfiguration = false

    contentView.addSubview(bubbleView)
    contentView.addSubview(tailView)

    contentView.addSubview(groupSenderNameLabel)
    contentView.addSubview(forwardedFromHeader)
    forwardedFromHeader.isHidden = true
    contentView.addSubview(messageLabel)
    contentView.addSubview(richTextView)
    contentView.addSubview(replyPreviewView)
    let tBase = censusActive ? ProcessInfo.processInfo.systemUptime : 0
    contentView.addSubview(mediaContainerView)
    // Image/video host first; soft material blur sits ABOVE still pixels (Telegram
    // transfer look) but below progress ring / play chrome.
    mediaContainerView.addSubview(mediaImageView)
    mediaContainerView.addSubview(mediaVideoPlayerHostView)
    // The transfer scrim and the sticker surface are built on demand and insert
    // themselves here — see `mediaPlaceholderBlurView` / `mediaStickerAnimationView`.
    mediaContainerView.addSubview(mediaPrimaryIconView)
    mediaContainerView.addSubview(mediaVoiceButtonView)
    mediaContainerView.addSubview(mediaTitleLabel)
    mediaContainerView.addSubview(mediaDetailLabel)
    mediaContainerView.addSubview(mediaWaveformView)
    mediaContainerView.addSubview(mediaVideoInfoBadgeView)
    mediaVideoInfoBadgeView.addSubview(mediaVideoTimeIconView)
    mediaVideoInfoBadgeView.addSubview(mediaDurationBadge)
    mediaVideoInfoBadgeView.addSubview(mediaVideoAudioIconView)
    mediaContainerView.addSubview(mediaProgressOverlayView)
    mediaProgressOverlayView.addSubview(mediaProgressRingView)
    mediaProgressOverlayView.addSubview(mediaProgressSpinner)
    mediaProgressOverlayView.addSubview(mediaProgressSizeLabel)
    mediaBorderLayer.fillColor = UIColor.clear.cgColor
    mediaBorderLayer.isHidden = true
    mediaContainerView.layer.addSublayer(mediaBorderLayer)
    let tMedia = censusActive ? ProcessInfo.processInfo.systemUptime : 0
    inlineAttachmentView.addSubview(inlineAttachmentIconView)
    inlineAttachmentView.addSubview(inlineAttachmentTitleLabel)
    inlineAttachmentView.addSubview(inlineAttachmentSubtitleLabel)
    contentView.addSubview(inlineAttachmentView)
    contentView.addSubview(metaContainerView)
    metaContainerView.addSubview(editedLabel)
    metaContainerView.addSubview(pinnedLabel)
    metaContainerView.addSubview(viewIconView)
    metaContainerView.addSubview(viewCountLabel)
    metaContainerView.addSubview(timestampLabel)
    metaContainerView.addSubview(statusImageView)
    metaContainerView.addSubview(statusLabel)
    metaContainerView.addSubview(pendingStatusView)
    let tAttachmentMeta = censusActive ? ProcessInfo.processInfo.systemUptime : 0
    contentView.addSubview(dayLabel)
    contentView.addSubview(serviceActionBarView)
    serviceActionBarView.isHidden = true
    serviceActionBarView.onAction = { [weak self] action in
      guard let self, let row = self.row else { return }
      self.onServiceDecisionAction?(row, action)
    }
    contentView.addSubview(retryButton)
    contentView.addSubview(agentRegenerateButton)
    contentView.addSubview(agentViewButton)
    contentView.addSubview(notSentIndicator)
    // `agentActionBarView` is built and wired on first use, not here.
    // `agentTurnContentView` is built and wired on first use, not here.

    contentView.addSubview(reactionStripView)
    reactionStripView.onHold = { [weak self] emoji, point in
      guard let self, let row = self.row else { return }
      self.onReactionHold?(row, emoji, point)
    }
    reactionStripView.onTap = { [weak self] emoji in
      guard let self, let row = self.row else { return }
      self.onReactionTap?(row, emoji)
    }
    contentView.addSubview(selectionCircleView)
    selectionCircleView.addTarget(self, action: #selector(handleSelectionToggle), for: .touchUpInside)

    messageLabel.numberOfLines = 0
    messageLabel.font = bubbleMessageFont
    messageLabel.textColor = .white

    groupSenderNameLabel.numberOfLines = 1
    groupSenderNameLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
    groupSenderNameLabel.lineBreakMode = .byTruncatingTail
    groupSenderNameLabel.isHidden = true
    // No text shadow: the name now sits INSIDE the bubble plate, where the tinted
    // background already carries it. The shadow existed only to keep it legible when it
    // floated over the wallpaper.

    mediaContainerView.clipsToBounds = true
    mediaContainerView.layer.cornerCurve = .continuous
    mediaContainerView.backgroundColor = UIColor(white: 0.0, alpha: 0.16)

    mediaImageView.backgroundColor = .clear
    mediaImageView.contentMode = .scaleAspectFill
    mediaImageView.clipsToBounds = true

    mediaVideoPlayerHostView.backgroundColor = .clear
    mediaVideoPlayerHostView.isHidden = true

    mediaPrimaryIconView.tintColor = .white
    mediaPrimaryIconView.contentMode = .center
    mediaPrimaryIconView.clipsToBounds = true
    mediaPrimaryIconView.backgroundColor = UIColor(white: 0.0, alpha: 0.28)
    mediaPrimaryIconView.layer.cornerCurve = .circular
    mediaPrimaryIconView.isUserInteractionEnabled = true
    let playTap = UITapGestureRecognizer(target: self, action: #selector(handleInlineVideoPlayTap))
    playTap.cancelsTouchesInView = true
    mediaPrimaryIconView.addGestureRecognizer(playTap)

    mediaVoiceButtonView.clipsToBounds = false
    mediaVoiceButtonView.isUserInteractionEnabled = true
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleVoiceTap))
    mediaVoiceButtonView.addGestureRecognizer(tap)
    mediaVoiceButtonView.applyStyle(
      fillColor: UIColor(white: 1.0, alpha: 0.96),
      iconTint: appearance.accent,
      ringTint: appearance.accent.withAlphaComponent(0.72))

    mediaTitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
    mediaTitleLabel.textColor = .white
    mediaTitleLabel.numberOfLines = 1

    mediaDetailLabel.font = UIFont.systemFont(ofSize: 11, weight: .regular)
    mediaDetailLabel.textColor = UIColor(white: 1.0, alpha: 0.82)
    mediaDetailLabel.numberOfLines = 1

    mediaVideoInfoBadgeView.backgroundColor = UIColor(white: 0.0, alpha: 0.56)
    mediaVideoInfoBadgeView.layer.cornerRadius = 11.0
    mediaVideoInfoBadgeView.layer.cornerCurve = .continuous
    mediaVideoInfoBadgeView.clipsToBounds = true
    mediaVideoInfoBadgeView.isHidden = true

    let mediaBadgeSymbolConfig = UIImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
    mediaVideoTimeIconView.image = UIImage(systemName: "timer", withConfiguration: mediaBadgeSymbolConfig)
    mediaVideoTimeIconView.tintColor = UIColor.white.withAlphaComponent(0.88)
    mediaVideoTimeIconView.contentMode = .scaleAspectFit
    mediaVideoTimeIconView.isHidden = true

    mediaVideoAudioIconView.tintColor = UIColor.white.withAlphaComponent(0.88)
    mediaVideoAudioIconView.contentMode = .scaleAspectFit
    mediaVideoAudioIconView.isHidden = true
    mediaVideoAudioIconView.isUserInteractionEnabled = true
    let audioTap = UITapGestureRecognizer(target: self, action: #selector(handleInlineVideoMuteTap))
    mediaVideoAudioIconView.addGestureRecognizer(audioTap)

    mediaDurationBadge.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
    mediaDurationBadge.textColor = .white
    mediaDurationBadge.backgroundColor = .clear
    mediaDurationBadge.textAlignment = .center
    mediaDurationBadge.clipsToBounds = false

    mediaProgressOverlayView.backgroundColor = .clear
    mediaProgressOverlayView.clipsToBounds = false

    mediaProgressRingView.isUserInteractionEnabled = true
    let ringCancelTap = UITapGestureRecognizer(
      target: self, action: #selector(handleMediaProgressCancelTap))
    mediaProgressRingView.addGestureRecognizer(ringCancelTap)

    mediaProgressSpinner.color = UIColor(white: 1.0, alpha: 0.85)
    mediaProgressSpinner.hidesWhenStopped = true
    mediaProgressSpinner.isHidden = true

    mediaProgressSizeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    mediaProgressSizeLabel.textColor = .white
    mediaProgressSizeLabel.backgroundColor = UIColor(white: 0.0, alpha: 0.50)
    mediaProgressSizeLabel.textAlignment = .center
    mediaProgressSizeLabel.clipsToBounds = true
    mediaProgressSizeLabel.layer.cornerRadius = 10.0
    mediaProgressSizeLabel.layer.cornerCurve = .continuous
    mediaProgressSizeLabel.isHidden = true
    mediaProgressSizeLabel.isUserInteractionEnabled = true
    let labelCancelTap = UITapGestureRecognizer(
      target: self, action: #selector(handleMediaProgressCancelTap))
    mediaProgressSizeLabel.addGestureRecognizer(labelCancelTap)

    inlineAttachmentView.layer.cornerCurve = .continuous
    inlineAttachmentView.layer.cornerRadius = 12.0
    inlineAttachmentView.clipsToBounds = true
    inlineAttachmentView.isUserInteractionEnabled = true
    let attachmentTap = UITapGestureRecognizer(
      target: self, action: #selector(handleInlineAttachmentTap))
    inlineAttachmentView.addGestureRecognizer(attachmentTap)

    inlineAttachmentIconView.contentMode = .scaleAspectFit
    inlineAttachmentIconView.tintColor = .white
    inlineAttachmentIconView.image = UIImage(systemName: "doc.text.fill")

    inlineAttachmentTitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
    inlineAttachmentTitleLabel.textColor = .white
    inlineAttachmentTitleLabel.numberOfLines = 1

    inlineAttachmentSubtitleLabel.font = UIFont.systemFont(ofSize: 11, weight: .regular)
    inlineAttachmentSubtitleLabel.textColor = UIColor(white: 1.0, alpha: 0.72)
    inlineAttachmentSubtitleLabel.numberOfLines = 1

    editedLabel.font = bubbleMetaFont
    pinnedLabel.font = bubbleMetaFont
    viewIconView.contentMode = .scaleAspectFit
    viewIconView.image = UIImage(
      systemName: "eye.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 9.0, weight: .medium))
    viewCountLabel.font = bubbleMetaFont
    timestampLabel.font = bubbleMetaFont
    timestampLabel.textColor = UIColor(white: 1.0, alpha: 0.72)
    statusImageView.contentMode = .scaleAspectFit
    statusImageView.isHidden = true
    pendingStatusView.isHidden = true
    statusLabel.font = bubbleMetaStatusFont
    statusLabel.textAlignment = .center
    // Resend: a glyph in the margin, not a badge.
    //
    // It used to be a 28pt disc with a saturated red plate behind an oversized
    // `arrow.clockwise` — a control loud enough for a destructive confirmation, drawn
    // once per failed row. A run that fails does not fail once, so the transcript filled
    // its left margin with a column of red buttons that outweighed the messages beside
    // them and read as damage rather than as "tap to send this again".
    //
    // This is the same treatment `agentRegenerateButton` already uses for the equivalent
    // gesture (borderless, icon-only, sized to the meta row, tinted rather than filled),
    // so the two "do it again" affordances in the transcript now look like each other.
    // The failure itself is still stated by the "!" in the bubble's meta row; this is
    // only the action.
    retryButton.isHidden = true
    retryButton.tintColor = UIColor(red: 0.98, green: 0.42, blue: 0.40, alpha: 0.92)
    retryButton.backgroundColor = .clear
    retryButton.layer.cornerRadius = 0
    retryButton.setImage(
      UIImage(
        systemName: "arrow.counterclockwise",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .semibold)),
      for: .normal)
    retryButton.imageView?.contentMode = .center
    retryButton.addTarget(self, action: #selector(handleRetryTap), for: .touchUpInside)

    // Agent regenerate — same side-of-bubble placement as the error retry
    // button, icon only (no text). Re-tinted to the theme in `configure`.
    agentRegenerateButton.isHidden = true
    agentRegenerateButton.layer.cornerCurve = .continuous
    agentRegenerateButton.layer.cornerRadius = 0
    agentRegenerateButton.backgroundColor = .clear
    agentRegenerateButton.setImage(
      UIImage(
        systemName: "arrow.counterclockwise",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 12.0, weight: .semibold)),
      for: .normal)
    agentRegenerateButton.imageView?.contentMode = .center
    agentRegenerateButton.addTarget(
      self, action: #selector(handleAgentRegenerateTap), for: .touchUpInside)

    // "View agent" — same side-of-bubble placement, icon only. Final styling/
    // placement is refined against the design; this mirrors the regenerate button.
    agentViewButton.isHidden = true
    agentViewButton.layer.cornerCurve = .continuous
    agentViewButton.layer.cornerRadius = 0
    agentViewButton.backgroundColor = .clear
    agentViewButton.setImage(
      UIImage(
        systemName: "chevron.forward.circle",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .semibold)),
      for: .normal)
    agentViewButton.imageView?.contentMode = .center
    agentViewButton.addTarget(
      self, action: #selector(handleViewAgentTap), for: .touchUpInside)

    notSentIndicator.isHidden = true
    notSentIndicator.contentMode = .center
    notSentIndicator.isUserInteractionEnabled = true
    notSentIndicator.addGestureRecognizer(
      UITapGestureRecognizer(target: self, action: #selector(handleNotSentTap)))
    // An outline mark, not a filled disc.
    //
    // `exclamationmark.circle.fill` at 17pt semibold is a solid saturated red plate, and
    // it is drawn once per failed row. On a transcript where a whole run failed — 512
    // consecutive rows, which is exactly what the stranded-pending repair surfaces — the
    // margin becomes a column of red discs shouting at the reader about something they
    // already know. Failure is a state, not an alarm: the same information reads fine as
    // a light outline glyph, and it stops competing with the message content beside it.
    notSentIndicator.tintColor = UIColor(red: 0.98, green: 0.42, blue: 0.40, alpha: 0.92)
    notSentIndicator.image = UIImage(
      systemName: "exclamationmark.circle",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 12.5, weight: .medium))

    dayLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
    dayLabel.textAlignment = .center
    dayLabel.textColor = UIColor(white: 0.95, alpha: 0.9)
    // The day pill is normally inert; it becomes tappable only while it is rendering an
    // agent-error notice (guarded in the handler by `isConfiguredAgentErrorNotice`).
    dayLabel.isUserInteractionEnabled = true
    dayLabel.addGestureRecognizer(
      UITapGestureRecognizer(target: self, action: #selector(handleAgentErrorNoticeTap)))

    bubbleView.isHidden = true
    tailView.isHidden = true
    // agentSenderLabel removed
    messageLabel.isHidden = true
    _agentTurnContentView?.isHidden = true
    richTextView.isHidden = true
    replyPreviewView.isHidden = true
    _linkPreviewView?.isHidden = true
    mediaContainerView.isHidden = true
    mediaPrimaryIconView.isHidden = true
    mediaVoiceButtonView.isHidden = true
    mediaTitleLabel.isHidden = true
    mediaDetailLabel.isHidden = true
    mediaWaveformView.isHidden = true
    mediaVideoInfoBadgeView.isHidden = true
    mediaDurationBadge.isHidden = true
    mediaProgressOverlayView.isHidden = true
    mediaProgressSizeLabel.isHidden = true
    inlineAttachmentView.isHidden = true
    metaContainerView.isHidden = true
    editedLabel.isHidden = true
    pinnedLabel.isHidden = true
    viewIconView.isHidden = true
    viewCountLabel.isHidden = true
    timestampLabel.isHidden = true
    statusImageView.isHidden = true
    statusLabel.isHidden = true
    dayLabel.isHidden = true
    reactionStripView.isHidden = true
    _agentActionBarView?.isHidden = true

    guard censusActive else { return }
    let tEnd = ProcessInfo.processInfo.systemUptime
    Self.initCensusBase += tBase - t0
    Self.initCensusMedia += tMedia - tBase
    Self.initCensusAttachmentMeta += tAttachmentMeta - tMedia
    Self.initCensusAgent += tEnd - tAttachmentMeta
    Self.propCensusBubble += clkPropsAfterBubble - clkPropertiesBegan
    Self.propCensusMedia += clkPropsAfterMedia - clkPropsAfterBubble
    Self.propCensusMeta += clkPropsAfterMeta - clkPropsAfterMedia
    Self.propCensusRest += clkPropsEnded - clkPropsAfterMeta
    Self.propCensusSuperInit += t0 - clkPropsEnded
    Self.initCensusSamples += 1
    guard Self.initCensusSamples == 20 else { return }
    let n = 20.0
    let us = { (total: Double) in total * 1_000_000 / n }
    NSLog(
      "[CellCost] init sections (avg of 20) base=%.0fus media=%.0fus attachment+meta=%.0fus agent+buttons+config=%.0fus TOTAL=%.0fus",
      us(Self.initCensusBase), us(Self.initCensusMedia), us(Self.initCensusAttachmentMeta),
      us(Self.initCensusAgent),
      us(
        Self.initCensusBase + Self.initCensusMedia + Self.initCensusAttachmentMeta
          + Self.initCensusAgent))
    NSLog(
      "[CellCost] stored properties (avg of 20) bubble+text=%.0fus media=%.0fus attachment+meta=%.0fus rest=%.0fus super.init=%.0fus TOTAL=%.0fus",
      us(Self.propCensusBubble), us(Self.propCensusMedia), us(Self.propCensusMeta),
      us(Self.propCensusRest), us(Self.propCensusSuperInit),
      us(
        Self.propCensusBubble + Self.propCensusMedia + Self.propCensusMeta
          + Self.propCensusRest + Self.propCensusSuperInit))
  }

  /// The pinned header date currently REPRESENTS this separator, so fade the in-list
  /// capsule: exactly one date capsule is on screen and it is the one attached under the
  /// header. Alpha only — the row keeps its height, so nothing shifts.
  func setDaySeparatorRepresentedByPinnedDate(_ represented: Bool) {
    let target: CGFloat = represented ? 0.0 : 1.0
    guard abs(dayLabel.alpha - target) > 0.01 else { return }
    dayLabel.alpha = target
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    inlineVideoLog(
      "didMoveToWindow window=\(window != nil ? "Y" : "N") active=\(mediaVideoPlaybackActive ? "Y" : "N")"
    )
    updateStickerAnimationPlayback()
    refreshInlineVideoPlaybackIfNeeded()
    updateWallpaperBackdropLayoutIfNeeded()
    refreshViewOnceShineCover()
  }

  func currentMediaImage() -> UIImage? {
    if let row, row.viewOnce {
      let key = row.messageId ?? row.key
      return chatViewOnceSealedImage(key: key)
    }
    return mediaImageView.image
  }

  /// The URL the cell's own inline AVPlayer actually resolved and is playing —
  /// local-cache-preferring, unlike the row's raw (often remote) mediaUrl. The
  /// floating mini-player must reuse this exact URL, not re-derive its own, or it
  /// silently fails to produce frames and only the seed image ever shows.
  func currentInlineVideoPlaybackURL() -> URL? {
    guard let key = mediaVideoPlayerURLKey else { return nil }
    return URL(string: key)
  }

  func currentMediaImageView() -> UIImageView? {
    mediaImageView
  }

  /// Image for one of a multi-image message's pictures (or the hero image when
  /// the message carries only one).
  func mediaImage(atGridIndex index: Int) -> UIImage? {
    if let stack = mediaStackView, !stack.isHidden, let image = stack.image(at: index) {
      return image
    }
    return mediaImageView.image
  }

  func mediaImageView(atGridIndex index: Int) -> UIImageView? {
    if let stack = mediaStackView, !stack.isHidden, let view = stack.imageView(at: index) {
      return view
    }
    return mediaImageView
  }

  /// Which picture the stack is currently showing — the one a tap opens and the
  /// one the zoom transition has to fly out of and back into.
  var currentMediaStackIndex: Int {
    guard let stack = mediaStackView, !stack.isHidden else { return 0 }
    return stack.currentIndex
  }

  var isInlineVideoPlaybackActive: Bool { mediaVideoPlaybackActive }

  func setInlineVideoPlaybackActive(_ active: Bool) {
    guard mediaVideoPlaybackActive != active else { return }
    mediaVideoPlaybackActive = active
    inlineVideoLog("setActive active=\(active ? "Y" : "N")")
    refreshInlineVideoPlaybackIfNeeded()
  }

  func lastTouchWasOnVideoPlayControl() -> Bool {
    guard let point = lastTouchPointInCell,
      ProcessInfo.processInfo.systemUptime - lastTouchAt < 2.0,
      !mediaPrimaryIconView.isHidden
    else { return false }
    let hit = mediaPrimaryIconView.convert(mediaPrimaryIconView.bounds, to: self)
      .insetBy(dx: -10.0, dy: -10.0)
    return hit.contains(point)
  }

  @objc private func handleInlineVideoPlayTap() {
    // Notes are toggled by the list (scale + expanded playback), never by this glyph.
    guard let row, row.visualKind == .video else { return }
    guard !row.shouldShowUploadOverlay, !mediaIsDownloading else { return }
    toggleInlineVideoPlayback()
  }

  func pauseInlineVideoForFullscreen() {
    mediaVideoUserPaused = true
    mediaVideoPlayer?.pause()
    refreshInlineVideoPlayGlyph()
  }

  func toggleInlineVideoPlayback() {
    guard row?.visualKind == .video || row?.visualKind == .videoNote else { return }
    if isInlineVideoPlayingNow() {
      mediaVideoUserPaused = true
      mediaVideoPlayer?.pause()
    } else {
      mediaVideoUserPaused = false
      mediaVideoHasCompletedOnce = false
      mediaVideoPlaybackActive = true
      mediaVideoUserInitiatedPlay = true
      if mediaVideoReady, mediaVideoPlayer != nil {
        configureInlineVideoAudioSession(muted: mediaVideoIsMuted || !mediaVideoHasAudio)
        mediaVideoPlayer?.play()
      } else {
        refreshInlineVideoPlaybackIfNeeded()
      }
    }
    refreshInlineVideoPlayGlyph()
  }

  private func isInlineVideoPlayingNow() -> Bool {
    mediaVideoPlayer?.timeControlStatus == .playing
  }

  private func refreshInlineVideoPlayGlyph() {
    guard let row, row.visualKind == .video || row.visualKind == .videoNote else { return }
    if shouldShowViewOnceShineCover(row) {
      mediaPrimaryIconView.isHidden = true
      return
    }
    if row.shouldShowUploadOverlay || mediaIsDownloading {
      mediaPrimaryIconView.isHidden = true
      return
    }
    let isNote = row.visualKind == .videoNote
    // An expanded note plays under a progress ring; the glyph would sit on top of it.
    if isNote, videoNoteExpandedPlayback {
      mediaPrimaryIconView.isHidden = true
      return
    }
    let playing = isInlineVideoPlayingNow() && !mediaVideoUserPaused
    let symbol = playing ? "pause.fill" : "play.fill"
    let point: CGFloat = isNote ? 22 : 24
    mediaPrimaryIconView.image = UIImage(systemName: symbol)?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: point, weight: .bold))
    mediaPrimaryIconView.isHidden = false
    mediaPrimaryIconView.alpha = 1.0
    mediaPrimaryIconView.tintColor = .white
    mediaPrimaryIconView.backgroundColor = UIColor.black.withAlphaComponent(playing ? 0.28 : 0.42)
    // A note glyph must not eat the tap — the scale lives on the list's row selection.
    mediaPrimaryIconView.isUserInteractionEnabled = !isNote
    mediaContainerView.bringSubviewToFront(mediaPrimaryIconView)
  }

  var onVideoNotePlaybackEnded: (() -> Void)?
  private var videoNoteExpandSessionAt: TimeInterval = 0

  func noteVideoNoteExpandSession() {
    videoNoteExpandSessionAt = ProcessInfo.processInfo.systemUptime
  }

  func beginVideoNoteExpandedPlayback() {
    noteVideoNoteExpandSession()
    mediaVideoPlaybackActive = true
    mediaVideoUserInitiatedPlay = true
    if let player = mediaVideoPlayer {
      configureInlineVideoAudioSession(muted: mediaVideoIsMuted || !mediaVideoHasAudio)
      player.seek(to: .zero)
      player.play()
    }
    refreshInlineVideoPlaybackIfNeeded()
    setVideoNoteExpandedPlayback(true)
  }

  func setVideoNoteExpandedPlayback(_ expanded: Bool) {
    guard row?.visualKind == .videoNote else { return }
    videoNoteExpandedPlayback = expanded
    UIView.animate(
      withDuration: 0.2,
      delay: 0,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.mediaPrimaryIconView.alpha = expanded ? 0 : 1
    }
    if expanded {
      ensureVideoNoteProgressRing()
      startVideoNoteProgressRing()
    } else {
      stopVideoNoteProgressRing()
    }
  }

  private var videoNoteScaleInFlight = false
  private var videoNoteExpandedPlayback = false
  private var videoNoteScaleOriginFrame: CGRect?

  /// Where the circle is right now, in window space, before the row is re-laid out.
  func captureVideoNoteScaleOrigin() {
    guard row?.visualKind == .videoNote, let host = mediaContainerView.superview else { return }
    videoNoteScaleOriginFrame = host.convert(mediaContainerView.frame, to: nil)
  }

  func prepareVideoNoteScale(from fromSide: CGFloat, to toSide: CGFloat) {
    guard row?.visualKind == .videoNote else { return }
    let view = mediaContainerView
    let s = max(0.01, fromSide / max(1.0, toSide))
    videoNoteScaleInFlight = true
    clipsToBounds = false
    contentView.clipsToBounds = false
    superview?.bringSubviewToFront(self)
    setVideoNoteScaleAnchor(CGPoint(x: 0.5, y: 1.0), on: view)
    // Start from where the circle actually was: a collapsed note is side-aligned and an
    // expanded one is centred, so scaling alone would begin at the wrong x.
    var dx: CGFloat = 0.0
    var dy: CGFloat = 0.0
    if let origin = videoNoteScaleOriginFrame, let host = view.superview {
      let target = host.convert(view.frame, to: nil)
      if target.width > 0.0, target.height > 0.0 {
        dx = origin.midX - target.midX
        dy = origin.maxY - target.maxY
      }
    }
    view.transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: s, y: s)
  }

  func settleVideoNoteScale() {
    mediaContainerView.transform = .identity
  }

  func endVideoNoteScale() {
    let view = mediaContainerView
    view.transform = .identity
    setVideoNoteScaleAnchor(CGPoint(x: 0.5, y: 0.5), on: view)
    videoNoteScaleInFlight = false
    videoNoteScaleOriginFrame = nil
  }

  private func setVideoNoteScaleAnchor(_ point: CGPoint, on view: UIView) {
    let bounds = view.bounds
    var newPoint = CGPoint(x: bounds.width * point.x, y: bounds.height * point.y)
    var oldPoint = CGPoint(
      x: bounds.width * view.layer.anchorPoint.x,
      y: bounds.height * view.layer.anchorPoint.y)
    newPoint = newPoint.applying(view.transform)
    oldPoint = oldPoint.applying(view.transform)
    var position = view.layer.position
    position.x -= oldPoint.x
    position.x += newPoint.x
    position.y -= oldPoint.y
    position.y += newPoint.y
    view.layer.position = position
    view.layer.anchorPoint = point
  }

  private var videoNoteProgressRing: CAShapeLayer?
  private var videoNoteProgressLink: CADisplayLink?

  private func ensureVideoNoteProgressRing() {
    if videoNoteProgressRing != nil { return }
    let ring = CAShapeLayer()
    ring.fillColor = UIColor.clear.cgColor
    ring.strokeColor = UIColor.white.withAlphaComponent(0.95).cgColor
    ring.lineWidth = 2.0
    ring.lineCap = .round
    ring.strokeEnd = 0
    // On the visible media circle (not bubbleView, which is chrome-hidden and
    // fully covered for full-bleed video notes) so the ring is actually seen.
    mediaContainerView.layer.addSublayer(ring)
    videoNoteProgressRing = ring
  }

  private func layoutVideoNoteProgressRingIfNeeded() {
    guard let ring = videoNoteProgressRing else { return }
    let bounds = mediaContainerView.bounds
    // The arc is a function of the container's size alone. Rebuilding the bezier every
    // display frame allocated a fresh path 120x/second AND handed CoreAnimation a path
    // change to implicitly animate — both landing on the scrolling main thread.
    guard ring.frame != bounds || ring.path == nil else { return }
    let inset: CGFloat = 2.0
    let path = UIBezierPath(
      arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
      radius: max(1, min(bounds.width, bounds.height) * 0.5 - inset),
      startAngle: -.pi / 2,
      endAngle: -.pi / 2 + .pi * 2,
      clockwise: true
    )
    ring.frame = bounds
    ring.path = path.cgPath
  }

  private func startVideoNoteProgressRing() {
    layoutVideoNoteProgressRingIfNeeded()
    videoNoteProgressLink?.invalidate()
    let link = CADisplayLink(target: self, selector: #selector(tickVideoNoteProgressRing))
    link.add(to: .main, forMode: .common)
    videoNoteProgressLink = link
  }

  private func stopVideoNoteProgressRing() {
    videoNoteProgressLink?.invalidate()
    videoNoteProgressLink = nil
    videoNoteProgressRing?.strokeEnd = 0
    videoNoteProgressRing?.removeFromSuperlayer()
    videoNoteProgressRing = nil
  }

  @objc private func tickVideoNoteProgressRing() {
    guard let ring = videoNoteProgressRing else { return }
    layoutVideoNoteProgressRingIfNeeded()
    let duration = max(0.01, mediaVideoTotalDuration ?? row?.duration ?? 1)
    // Read the player, not the 4Hz observer mirror: the ring is redrawn per frame, so it
    // may as well advance per frame instead of stepping four times a second.
    let live = _mediaVideoPlayerLayer?.player?.currentTime()
    let current = max(
      0, live.map { $0.isNumeric ? CMTimeGetSeconds($0) : mediaVideoCurrentTime }
        ?? mediaVideoCurrentTime)
    let next = CGFloat(min(1, current / duration))
    guard abs(ring.strokeEnd - next) > 0.0005 else { return }
    // strokeEnd is animatable, and this layer is not view-backed — without an explicit
    // transaction every frame's write starts its own 0.25s implicit animation.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ring.strokeEnd = next
    CATransaction.commit()
  }

  /// Lightweight selection chrome update — no full reconfigure (avoids media pop / flicker).
  /// Parent drives `layoutIfNeeded` inside a spring animation for smooth X inset.
  func applyMessageSelectionState(
    mode: Bool,
    selected: Bool,
    appearance: ChatListAppearance,
    animated: Bool
  ) {
    let modeChanged = selectionMode != mode
    selectionMode = mode
    self.appearance = appearance
    let showSelectionChrome = mode && !isGhostHidden
    if showSelectionChrome {
      selectionCircleView.isHidden = false
      selectionCircleView.setSelectionChromeVisible(true, animated: animated && modeChanged)
    } else if !selectionCircleView.isHidden {
      selectionCircleView.setSelectionChromeVisible(false, animated: animated && modeChanged)
    } else {
      selectionCircleView.isHidden = true
    }
    selectionCircleView.configure(
      selected: selected, appearance: appearance, animated: animated)
    // Hide side agent actions while selecting (same as full configure).
    if mode {
      agentRegenerateButton.isHidden = true
      agentViewButton.isHidden = true
    }
    setNeedsLayout()
  }

  func applyAppearance(_ appearance: ChatListAppearance) {
    self.appearance = appearance
    dayLabel.textColor = appearance.dayTextColor
    dayLabel.backgroundColor = appearance.dayBackgroundColor
    // Clean solid capsule — no hairline border. The corner radius is set in layout,
    // where the pill's real height is known (fully-rounded capsule).
    dayLabel.layer.borderWidth = 0.0
    dayLabel.layer.cornerCurve = .circular
    dayLabel.clipsToBounds = true
    let isCurrentRowMe = row?.isMe == true
    // Only a voice/music row ever shows the plate and waveform, but both are non-lazy
    // stored properties, so restyling them here charged every text bubble in the
    // transcript for voice chrome — a knockout-mask render included — on each
    // `cellForItemAt`. A voice row still gets its colors from `configure`, which calls
    // this same helper, so gating here loses nothing.
    if row?.visualKind == .voice {
      applyVoiceChromeColors(isMe: isCurrentRowMe)
    }
    // Only re-style a scrim that exists. A cell with no media has nothing to restyle, and
    // the lazy initializer already reads the current appearance when it does build one.
    _mediaPlaceholderBlurView?.effect = UIBlurEffect(
      style: appearance.isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight
    )
    _mediaPlaceholderTintView?.backgroundColor = UIColor(
      white: appearance.isDark ? 0.02 : 0.98,
      alpha: appearance.isDark ? 0.18 : 0.10
    )
    replyPreviewView.applyAppearance(appearance, isMe: isCurrentRowMe)
    _linkPreviewView?.applyAppearance(appearance, isMe: isCurrentRowMe)
    updateInlineVideoAudioIcon()
    updateMediaPlaceholderVisibility()
    setNeedsLayout()
  }

  func applyWallpaperBackdrop(
    snapshot: CGImage?,
    containerSize: CGSize,
    coordinateView: UIView?
  ) {
    wallpaperBackdropSnapshot = snapshot
    wallpaperBackdropContainerSize = containerSize
    wallpaperCoordinateView = coordinateView
    updateWallpaperBackdropLayoutIfNeeded()
  }

  func configure(
    row: ChatListRow,
    hiddenMessageId: String?,
    skipRemoteMediaLoad: Bool = false,
    preferredLocalMediaURLOverride: String? = nil,
    selectionMode: Bool = false,
    selected: Bool = false,
    agentTurnState: AgentTurnBubbleState = AgentTurnBubbleState(),
    groupExtraLeading: CGFloat = 0.0,
    groupSenderName: String? = nil,
    groupSenderColor: UIColor? = nil,
    groupSenderNameHeight: CGFloat = 0.0,
    groupTopSpacing: CGFloat = 0.0,
    replyAccentColors: (UIColor, UIColor)? = nil
  ) {
    let previousRow = self.row
    let isSameMessageIdentity = previousRow.map {
      ($0.messageId ?? $0.key) == (row.messageId ?? row.key)
    } ?? false
    if previousRow != nil, !isSameMessageIdentity {
      resetTallBubbleInnerContentAnimation()
    }
    // Status, roster, foreground, and selection updates reconfigure the same visible
    // cell. Keep its decoded pixels through that synchronous pass so an image never
    // flashes to the placeholder while the identical cache entry is looked up again.
    // Message-scoped: a local→remote promotion or a patched local url is the same picture,
    // so its pixels and quality stamp survive. Only a different remote identity is new media.
    let isSameMediaIdentity = previousRow.map {
      isSameMessageIdentity
        && $0.visualKind == row.visualKind
        && chatMediaRowsShareRemoteIdentity($0, row)
    } ?? false
    let mediaKindChanged = previousRow.map { $0.visualKind != row.visualKind } ?? true
    let preservedMediaImage = isSameMediaIdentity ? mediaImageView.image : nil
    if !isSameMessageIdentity || mediaKindChanged {
      mediaPixelQuality = .none
      documentPageCount = nil
      documentByteSize = nil
    } else if mediaImageView.image != nil, mediaPixelQuality == .none {
      // Reused cell with pixels but no quality stamp (old path) — treat as full so
      // a late micro-thumb cannot downgrade a sharp image.
      mediaPixelQuality = .full
    }
    // [MediaPop] reference point: image applies within ~1 frame of this stamp are the
    // synchronous configure pass (invisible); later applies on a window-attached cell
    // are the visible pop the flicker reports describe.
    lastConfigureStartedAt = ProcessInfo.processInfo.systemUptime
    self.agentTurnState = agentTurnState
    isConfiguredAgentDivider = false
    isConfiguredServiceDecision = false
    serviceActionBarView.isHidden = true
    serviceActionBarView.configure(actions: [], appearance: appearance)
    _serviceDecisionCardView?.isHidden = true
    isConfiguredAgentErrorNotice = false
    let activeVoiceSnapshot = VoiceBubblePlaybackCoordinator.shared.currentSnapshot
    self.row = row
    self.selectionMode = selectionMode
    self.isSelectionChecked = selected
    cachedLayoutMetrics = nil

    let rowId = row.messageId ?? row.key
    bubbleView.debugRowId = rowId
    let prevGroupLeading = groupExtraLeading
    let prevGroupName = groupSenderNameLabel.text
    let prevGroupColor = groupSenderNameLabel.textColor

    // Group sender decoration (name label + reserved avatar gutter). A name is only passed
    // for the first message of a sender-run; the gutter is reserved for every incoming
    // group message so consecutive bubbles stay aligned under the floating avatar.
    self.groupExtraLeading = max(0.0, groupExtraLeading)
    groupTopReservedSpacing = max(0.0, groupTopSpacing)
    // Palette belongs only to the quoted reply preview, not the sender name strip.
    self.replyAccentColors = replyAccentColors

    // Top-of-plate chrome: optional group sender name + optional forward header.
    // Heights must match `ChatListView.groupMeasurementExtras` so content never overlaps.
    // Selection mode hides the sender name (and Ready/typing-style chrome) so the
    // lift feels clean — reserve height stays 0 so rows don't keep empty name air.
    var topChromeHeight: CGFloat = 0.0
    if !selectionMode, let groupSenderName, !groupSenderName.isEmpty {
      groupSenderNameLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
      groupSenderNameLabel.text = groupSenderName
      groupSenderNameLabel.textColor = groupSenderColor ?? .secondaryLabel
      groupSenderNameLabel.isHidden = false
      topChromeHeight += max(groupSenderNameHeight, 0.0)
    } else {
      groupSenderNameLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
      groupSenderNameLabel.text = nil
      groupSenderNameLabel.isHidden = true
    }

    if row.isForwarded {
      let name = row.forwardedFromName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      // Match bubble body text (white on me / dark-or-light on them) — not accent green.
      let bodyTextColor = row.isMe ? appearance.textColorMe : appearance.textColorThem
      forwardedFromHeader.configure(
        name: name.isEmpty ? "Unknown" : name,
        avatarURL: row.forwardedFromAvatar,
        peerUserId: row.forwardedFromUserId,
        textColor: bodyTextColor,
        isDark: appearance.isDark
      )
      forwardedFromHeader.isHidden = false
      topChromeHeight += ForwardedFromHeaderView.preferredHeight
    } else {
      forwardedFromHeader.prepareForReuse()
      forwardedFromHeader.isHidden = true
    }
    groupNameReservedHeight = topChromeHeight
    // Group list color flicker: log gutter/name/sender-color transitions + style path.
    if chatCellBubbleFlickerDebugLogs,
      groupExtraLeading > 0.1 || prevGroupLeading > 0.1 || row.isGroupOrChannel
    {
      let stylePath: String
      if row.isAgentMessage {
        stylePath = "agent"
      } else if row.isAgentMention {
        stylePath = "agentMention"
      } else {
        stylePath = "normal"
      }
      let colorHex: String = {
        guard let c = groupSenderColor else { return "nil" }
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(
          format: "#%02X%02X%02X",
          Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
      }()
      let prevColorHex: String = {
        guard let c = prevGroupColor else { return "nil" }
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(
          format: "#%02X%02X%02X",
          Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
      }()
      NSLog(
        "[BubbleFlicker] cell.configure id=%@ kind=%@ style=%@ isMe=%@ isGroup=%@ agent=%@ stream=%@ gutter %.0f->%.0f name '%@'->'%@' color %@->%@ sameMedia=%@ shapeTail=%@",
        rowId,
        String(describing: row.kind),
        stylePath,
        row.isMe ? "Y" : "N",
        row.isGroupOrChannel ? "Y" : "N",
        row.isAgentMessage ? "Y" : "N",
        row.isStreamingText ? "Y" : "N",
        prevGroupLeading,
        groupExtraLeading,
        prevGroupName ?? "—",
        groupSenderNameLabel.text ?? "—",
        prevColorHex,
        colorHex,
        isSameMediaIdentity ? "Y" : "N",
        row.shape.showTail ? "Y" : "N"
      )
    }
    if row.visualKind == .voice, activeVoiceSnapshot.messageId == row.messageId {
      mediaNeedsDownload = activeVoiceSnapshot.isDownloading
      mediaIsDownloading = activeVoiceSnapshot.isDownloading
      mediaDownloadProgress = activeVoiceSnapshot.downloadFraction.map(Double.init)
        ?? activeVoiceSnapshot.downloadProgress.map(Double.init)
      mediaDownloadedBytes = activeVoiceSnapshot.downloadedBytes
      mediaTotalDownloadBytes = activeVoiceSnapshot.totalBytes
    } else {
      mediaNeedsDownload = false
      mediaIsDownloading = false
      mediaDownloadProgress = nil
      mediaDownloadedBytes = nil
      mediaTotalDownloadBytes = nil
    }
    self.skipRemoteMediaLoad = skipRemoteMediaLoad
    self.preferredLocalMediaURLOverride = preferredLocalMediaURLOverride
    _agentActionBarView?.isHidden = true
    agentRegenerateButton.isHidden = true
    agentViewButton.isHidden = true

    if row.kind == .message, row.messageType == "agent_actions" {
      isGhostHidden = hiddenMessageId == row.messageId
      VoiceBubblePlaybackCoordinator.shared.unbind(cell: self)
      resetStickerAnimation()
      stopTypingShimmer()
      richTextView.reset()
      resetAgentTurnContent()
      replyPreviewView.reset()
      _linkPreviewView?.reset()
      dayLabel.isHidden = true
      bubbleView.isHidden = true
      tailView.isHidden = true
      messageLabel.isHidden = true
      _agentTurnContentView?.isHidden = true
      richTextView.isHidden = true
      replyPreviewView.isHidden = true
      _linkPreviewView?.isHidden = true
      mediaContainerView.isHidden = true
      inlineAttachmentView.isHidden = true
      metaContainerView.isHidden = true
      reactionStripView.isHidden = true
      retryButton.isHidden = true
      selectionCircleView.isHidden = true
      mediaProgressSpinner.stopAnimating()
      mediaProgressOverlayView.isHidden = true
      mediaProgressSizeLabel.isHidden = true
      _agentActionBarView?.isHidden = isGhostHidden
      if !isGhostHidden {
        _ = agentActionBarView.configure(
          row: row,
          appearance: appearance,
          availableWidth: max(1.0, bounds.width - (bubbleSideMargin * 2.0))
        )
      }
      setNeedsLayout()
      return
    }

    switch row.kind {
    case .day:
      isGhostHidden = false
      resetStickerAnimation()
      resetAgentTurnContent()
      richTextView.reset()
      replyPreviewView.reset()
      _linkPreviewView?.reset()
      dayLabel.text = row.label
      dayLabel.isHidden = false
      bubbleView.isHidden = true
      tailView.isHidden = true
      messageLabel.isHidden = true
      _agentTurnContentView?.isHidden = true
      richTextView.isHidden = true
      replyPreviewView.isHidden = true
      _linkPreviewView?.isHidden = true
      mediaContainerView.isHidden = true
      inlineAttachmentView.isHidden = true
      metaContainerView.isHidden = true
      reactionStripView.isHidden = true
      mediaProgressSpinner.stopAnimating()
      mediaProgressOverlayView.isHidden = true
      mediaProgressSizeLabel.isHidden = true
      selectionCircleView.isHidden = true
    case .message:
      // Agent control/context events (interrupt, /compact) render as a centered muted
      // divider — reusing the day-pill so they look exactly like the mid-chat time/day
      // separators the user already knows — instead of leaking into the transcript as a
      // user or assistant bubble. Bypass all the bubble machinery below.
      if let dividerText = agentSystemDividerText(for: row) {
        isConfiguredAgentDivider = true
        let liveActions = row.serviceMessage?.hasLiveActions == true
          ? (row.serviceMessage?.actions ?? [])
          : []
        isConfiguredServiceDecision = !liveActions.isEmpty
        self.isGhostHidden = false
        VoiceBubblePlaybackCoordinator.shared.unbind(cell: self)
        resetStickerAnimation()
        stopTypingShimmer()
        richTextView.reset()
        resetAgentTurnContent()
        replyPreviewView.reset()
        _linkPreviewView?.reset()
        dayLabel.text = dividerText
        dayLabel.isHidden = false
        bubbleView.isHidden = true
        tailView.isHidden = true
        messageLabel.isHidden = true
        _agentTurnContentView?.isHidden = true
        richTextView.isHidden = true
        replyPreviewView.isHidden = true
        _linkPreviewView?.isHidden = true
        mediaContainerView.isHidden = true
        inlineAttachmentView.isHidden = true
        metaContainerView.isHidden = true
        reactionStripView.isHidden = true
        retryButton.isHidden = true
        _agentActionBarView?.isHidden = true
        if liveActions.isEmpty {
          serviceActionBarView.isHidden = true
          serviceActionBarView.configure(actions: [], appearance: appearance)
          _serviceDecisionCardView?.isHidden = true
        } else {
          serviceActionBarView.configure(actions: liveActions, appearance: appearance)
          serviceActionBarView.isHidden = false
          let risk = serviceDecisionRisk(for: row)
          let detail = serviceDecisionDetailText(for: row)
          if risk == nil, detail == nil {
            _serviceDecisionCardView?.isHidden = true
          } else {
            let card = serviceDecisionCardView
            card.configure(risk: risk, detail: detail, appearance: appearance)
            card.isHidden = false
          }
        }
        mediaProgressSpinner.stopAnimating()
        mediaProgressOverlayView.isHidden = true
        mediaProgressSizeLabel.isHidden = true
        selectionCircleView.isHidden = true
        setNeedsLayout()
        return
      }

      // A failed agent turn renders as a centered, tappable "Something went wrong ·
      // Try again" pill — same centered day-pill machinery as the divider above, but
      // warning-tinted and interactive — instead of leaking the raw provider error into
      // the transcript as an assistant bubble with in-cell retry chrome.
      if let errorText = agentErrorNoticeText(for: row) {
        isConfiguredAgentDivider = true
        isConfiguredAgentErrorNotice = true
        self.isGhostHidden = false
        VoiceBubblePlaybackCoordinator.shared.unbind(cell: self)
        resetStickerAnimation()
        stopTypingShimmer()
        richTextView.reset()
        resetAgentTurnContent()
        replyPreviewView.reset()
        _linkPreviewView?.reset()
        dayLabel.attributedText = agentErrorNoticeAttributedText(message: errorText)
        dayLabel.isHidden = false
        bubbleView.isHidden = true
        tailView.isHidden = true
        messageLabel.isHidden = true
        _agentTurnContentView?.isHidden = true
        richTextView.isHidden = true
        replyPreviewView.isHidden = true
        _linkPreviewView?.isHidden = true
        mediaContainerView.isHidden = true
        inlineAttachmentView.isHidden = true
        metaContainerView.isHidden = true
        reactionStripView.isHidden = true
        retryButton.isHidden = true
        agentRegenerateButton.isHidden = true
        agentViewButton.isHidden = true
        notSentIndicator.isHidden = true
        _agentActionBarView?.isHidden = true
        serviceActionBarView.isHidden = true
        mediaProgressSpinner.stopAnimating()
        mediaProgressOverlayView.isHidden = true
        mediaProgressSizeLabel.isHidden = true
        selectionCircleView.isHidden = true
        setNeedsLayout()
        return
      }
      let isGhostHidden = hiddenMessageId == row.messageId
      let usesTransparentAgentStreaming = usesTransparentAgentStreamingLayout(row)
      let usesAgentTurnContent = bubbleUsesAgentTurnContent(row)
      let usesBlockLayout = bubbleUsesBlockLayout(row)
      let previewURL = bubblePreviewURL(for: row)
      let showsReplyPreview = hasReplyPreview(row)
      self.isGhostHidden = isGhostHidden
      dayLabel.isHidden = true
      bubbleView.isHidden = false
      tailView.isHidden = isGhostHidden || !row.shape.showTail
      messageLabel.isHidden =
        isGhostHidden || usesAgentTurnContent
        || !(row.visualKind == .text || hasMediaCaptionLayout(row)) || usesBlockLayout
      // The old simplified preview is fully retired (see bubbleUsesAgentTurnContent) —
      // always hidden now; agentTurnContentView carries the real interleaved feed.
      // Read through the optional: this line runs for every message in the transcript,
      // and touching the panel property here would build one per cell — undoing the
      // laziness entirely while looking like a plain visibility assignment.
      if usesAgentTurnContent && !isGhostHidden {
        agentTurnContentView.isHidden = false
      } else {
        _agentTurnContentView?.isHidden = true
        resetAgentTurnContent()
      }
      richTextView.isHidden = isGhostHidden || usesAgentTurnContent || !usesBlockLayout
      replyPreviewView.isHidden = isGhostHidden || !showsReplyPreview
      // Runs for every message row — read through the optional so a transcript with no
      // links never builds a single preview card.
      if previewURL != nil && !isGhostHidden && !usesAgentTurnContent {
        linkPreviewView.isHidden = false
      } else {
        _linkPreviewView?.isHidden = true
      }
      if !usesAgentTurnContent
        && (row.messageType == "typing" || row.messageType == "agent_progress_tree")
      {
        // Agent "Thinking…" / tool-progress placeholders shimmer like typing.
        startTypingShimmer()
        messageLabel.font =
          row.messageType == "typing"
          ? UIFont.systemFont(ofSize: 13, weight: .regular)
          : bubbleMessageFont
      } else {
        stopTypingShimmer()
        messageLabel.font = bubbleMessageFont
      }
      mediaContainerView.isHidden = isGhostHidden || row.visualKind == .text
      inlineAttachmentView.isHidden = isGhostHidden || !hasInlineAttachment(row)
      // Hide the timestamp on an agent bubble until the response is finalized —
      // otherwise the time reserves width and balloons the empty/"Thinking…"
      // bubble. Covers the streaming-text, typing, and progress-tree phases.
      metaContainerView.isHidden =
        isGhostHidden || usesTransparentAgentStreaming || agentResponsePlaceholder(row)
        || usesAgentTurnContent
      let showSelectionChrome = selectionMode && !isGhostHidden
      if showSelectionChrome {
        selectionCircleView.isHidden = false
        selectionCircleView.setSelectionChromeVisible(true, animated: true)
      } else if !selectionCircleView.isHidden {
        selectionCircleView.setSelectionChromeVisible(false, animated: true)
      } else {
        selectionCircleView.isHidden = true
      }
      selectionCircleView.configure(selected: selected, appearance: appearance, animated: true)

      // Side regenerate button on completed agent bubbles (replaces the old
      // bottom action bar). Hidden while streaming / in selection mode.
      let showsRegenerate = !isGhostHidden && !selectionMode && showsAgentRegenerate(row)
      agentRegenerateButton.isHidden = !showsRegenerate
      if showsRegenerate {
        agentRegenerateButton.tintColor = appearance.timeColorThem.withAlphaComponent(0.75)
        agentRegenerateButton.backgroundColor = .clear
      }

      // "View agent" side button on every completed agent bubble (not errored —
      // those show regenerate instead). Opens the native full-page agent surface.
      let showsViewAgent = !isGhostHidden && !selectionMode && showsAgentView(row)
      agentViewButton.isHidden = !showsViewAgent
      if showsViewAgent {
        agentViewButton.tintColor = appearance.timeColorThem.withAlphaComponent(0.75)
        agentViewButton.backgroundColor = .clear
      }

      // "Not sent" indicator on a failed outgoing message — sits in the me-side
      // margin and slides in once when the failure first appears.
      // `isDeliveryFailed` is the row's own verdict; `status == "error"` is the send
      // pipeline's. They disagree often enough that the transcript used to show a bare
      // arrow button with no failure mark, or a mark with no way to act on it. Either one
      // means this message did not go out.
      let showsNotSent =
        !isGhostHidden && !selectionMode && row.isMe
        && (row.isDeliveryFailed || row.status?.lowercased() == "error")
      let wasNotSentVisible = !notSentIndicator.isHidden
      notSentIndicator.isHidden = !showsNotSent
      if !showsNotSent {
        notSentIndicatorShown = false
      } else if !wasNotSentVisible {
        // First reveal for this cell — animate in layoutSubviews once positioned.
        notSentIndicatorShown = false
      }

      // Agent/Mention labeling
      let isTyping = row.messageType == "typing"
      let messageFont =
        isTyping ? UIFont.systemFont(ofSize: 13, weight: .regular) : bubbleMessageFont
      let resolveTextColor = row.isMe ? appearance.textColorMe : appearance.textColorThem
      let displayText = bubbleDisplayAttributedString(
        for: row, font: messageFont, textColor: resolveTextColor)
      // Keep RTL glyph shaping, but place the body at the plate's left inset.
      // Absolute .left avoids .natural resolving right under forceRightToLeft.
      let rtlBody = isRTL(displayText.string)
      messageLabel.textAlignment = rtlBody ? .left : .natural
      messageLabel.semanticContentAttribute = rtlBody ? .forceRightToLeft : .unspecified
      if messageLabel.isHidden {
        messageLabel.resetStreamingState()
      } else {
        messageLabel.applyStreamingText(
          displayText,
          rawText: displayText.string,
          isStreaming: row.isAgentMessage && row.isStreamingText && row.messageType != "typing"
        )
      }
      if let previewURL, _linkPreviewView?.isHidden == false {
        linkPreviewView.configure(url: previewURL, appearance: appearance, isMe: row.isMe)
      } else {
        _linkPreviewView?.reset()
      }
      if !replyPreviewView.isHidden {
        replyPreviewView.configure(
          title: replyPreviewTitle(for: row),
          text: replyPreviewText(for: row),
          appearance: appearance,
          isMe: row.isMe,
          accentColors: replyAccentColors
        )
      } else {
        replyPreviewView.reset()
      }
      editedLabel.text = "edited"
      pinnedLabel.text = "pinned"
      editedLabel.isHidden = !row.isEdited
      pinnedLabel.isHidden = !row.isPinned
      if let viewCount = row.viewCount {
        viewCountLabel.setCounterText(
          compactEngagementCount(viewCount), animated: isSameMessageIdentity)
      }
      timestampLabel.text = row.timestamp

      if !row.reactions.isEmpty {
        reactionStripView.isHidden = isGhostHidden || usesTransparentAgentStreaming
        reactionStripView.configure(
          reactions: row.reactions, appearance: appearance, isMe: row.isMe,
          chatId: hostChatId, messageId: row.messageId ?? row.key,
          showsCount: row.isGroupOrChannel, animated: isSameMessageIdentity)
        reactionDebugLog(
          "configure id=\(row.messageId ?? "nil") reactions=\(row.reactions.count) hidden=\(isGhostHidden ? "Y" : "N")"
        )
      } else {
        reactionStripView.isHidden = true
      }

      if row.isAgentMessage {
        if usesTransparentAgentStreaming {
          bubbleView.clearAgentStyle()
          tailView.clearAgentTailStyle()
          bubbleView.configure(
            isMe: false,
            shape: chatAppearanceBubbleShape(row.shape, appearance: appearance),
            hidden: true,
            appearance: appearance
          )
          tailView.setImage(nil)
          tailView.configure(
            isMe: false,
            visible: false,
            appearance: appearance
          )
        } else {
          // Agent messages use "them" styling (not isMe) with a subtle tint
          bubbleView.configure(
            isMe: false,
            shape: chatAppearanceBubbleShape(row.shape, appearance: appearance),
            hidden: isGhostHidden,
            appearance: appearance)
          bubbleView.applyAgentStyle(
            appearance: appearance, isMe: false, accent: Self.agentWorkingAccent(for: row))
          tailView.configure(
            isMe: false,
            visible: !isGhostHidden && row.shape.showTail,
            appearance: appearance
          )
          tailView.applyAgentTailStyle(
            appearance: appearance,
            isMe: false,
            accent: Self.agentWorkingAccent(for: row)
          )
        }
      } else if row.isAgentMention {
        // Agent mention by ME uses "me" styling with glow
        bubbleView.configure(
          isMe: true,
          shape: chatAppearanceBubbleShape(row.shape, appearance: appearance),
          hidden: isGhostHidden,
          appearance: appearance)
        bubbleView.applyAgentStyle(appearance: appearance, isMe: true)
        tailView.configure(
          isMe: true,
          visible: !isGhostHidden && row.shape.showTail,
          appearance: appearance
        )
        tailView.applyAgentTailStyle(appearance: appearance, isMe: true)
      } else {
        bubbleView.clearAgentStyle()
        tailView.clearAgentTailStyle()
        let hideBubbleForTyping = row.messageType == "typing"
        let hideBubbleForSticker = isTransparentStickerMessage(row)
        let hideBubbleForFullBleedMedia = usesFullBleedMediaLayout(row)
        let hideBubbleChrome = hideBubbleForTyping || hideBubbleForSticker || hideBubbleForFullBleedMedia
        bubbleView.configure(
          isMe: row.isMe,
          shape: chatAppearanceBubbleShape(row.shape, appearance: appearance),
          hidden: isGhostHidden || hideBubbleChrome,
          appearance: appearance)
        tailView.configure(
          isMe: row.isMe,
          visible: !isGhostHidden && row.shape.showTail && !hideBubbleChrome,
          appearance: appearance
        )
        if hideBubbleForSticker {
          tailView.setImage(nil)
        }
      }
      let textColor =
        row.isMe
        ? appearance.textColorMe
        : (row.isAgentMessage ? appearance.textColorThem : appearance.textColorThem)
      let usesViewOnceMetaPlate =
        row.viewOnce && usesFullBleedMediaLayout(row) && row.visualKind != .videoNote
      let metaColor =
        usesViewOnceMetaPlate
        ? UIColor(white: 1.0, alpha: 0.92)
        : resolvedMetaColor(for: textColor)
      messageLabel.textColor = textColor
      editedLabel.textColor = metaColor
      pinnedLabel.textColor = metaColor
      viewIconView.tintColor = metaColor
      viewCountLabel.textColor = metaColor
      timestampLabel.textColor = metaColor
      metaContainerView.backgroundColor =
        usesViewOnceMetaPlate ? UIColor.black.withAlphaComponent(0.48) : .clear
      metaContainerView.clipsToBounds = usesViewOnceMetaPlate
      configureMediaPresentation(
        for: row,
        textColor: textColor,
        metaColor: metaColor,
        preservedMediaImage: preservedMediaImage,
        isSameMessage: isSameMessageIdentity,
        mediaKindChanged: mediaKindChanged
      )
      if !inlineAttachmentView.isHidden {
        inlineAttachmentView.backgroundColor = UIColor(white: 0.0, alpha: 0.20)
        inlineAttachmentIconView.image = UIImage(systemName: inlineAttachmentIconName(for: row))
        inlineAttachmentTitleLabel.text = inlineAttachmentTitle(for: row)
        inlineAttachmentSubtitleLabel.text = inlineAttachmentSubtitle(for: row)
      } else {
        inlineAttachmentIconView.image = UIImage(systemName: "doc.text.fill")
        inlineAttachmentTitleLabel.text = nil
        inlineAttachmentSubtitleLabel.text = nil
      }
      configureStatus(for: row, baseColor: metaColor)
      if row.visualKind == .voice {
        VoiceBubblePlaybackCoordinator.shared.bind(
          cell: self,
          messageId: row.messageId,
          mediaURL: resolvedVoicePlaybackURL(for: row),
          mediaKey: row.mediaKey,
          fileName: row.fileName)
        applyExternalVoicePlaybackIfNeeded()
      } else {
        VoiceBubblePlaybackCoordinator.shared.unbind(cell: self)
      }
      // Use full opacity — visibility is controlled by isHidden, not alpha.
      // This eliminates the 0→1 opacity flicker that plagued updates.
      messageLabel.alpha = 1.0
      _agentTurnContentView?.alpha = 1.0
      richTextView.alpha = 1.0
      replyPreviewView.alpha = 1.0
      _linkPreviewView?.alpha = 1.0
      inlineAttachmentView.alpha = 1.0
      mediaContainerView.alpha = 1.0
      metaContainerView.alpha = 0.72
      reactionStripView.alpha = 1.0
    }

    if hasSavedExtractionState {
      // Extraction forces bubble/tail hidden; re-saving those here would latch it as the
      // restore target and leave the cell showing only its reaction pill.
      if !isContextMenuExtracted {
        savedBubbleHiddenBeforeExtraction = bubbleView.isHidden
        savedTailHiddenBeforeExtraction = tailView.isHidden
      }
      savedReactionHiddenBeforeExtraction = reactionStripView.isHidden
      savedMessageAlphaBeforeExtraction = messageLabel.alpha
      savedAgentTurnContentAlphaBeforeExtraction = _agentTurnContentView?.alpha ?? 1.0
      savedRichTextAlphaBeforeExtraction = richTextView.alpha
      savedReplyPreviewAlphaBeforeExtraction = replyPreviewView.alpha
      savedLinkPreviewAlphaBeforeExtraction = _linkPreviewView?.alpha ?? 1.0
      savedInlineAttachmentAlphaBeforeExtraction = inlineAttachmentView.alpha
      savedMediaAlphaBeforeExtraction = mediaContainerView.alpha
      savedMetaAlphaBeforeExtraction = metaContainerView.alpha
    }

    applyContextMenuExtractionIfNeeded()
    setNeedsLayout()
  }

  override func prepareForReuse() {
    let reuseStartedAt = ProcessInfo.processInfo.systemUptime
    // Tear down animated/media owners before UIKit resets its cell configuration state.
    layer.removeAllAnimations()
    contentView.layer.removeAllAnimations()
    pendingStatusView.stopAnimating()
    stopTypingShimmer()
    stopInlineVideoPlayback(resetMutedState: true)
    stopVideoNoteProgressRing()
    videoNoteExpandedPlayback = false
    mediaPrimaryIconView.alpha = 1.0
    resetStickerAnimation()
    lastTouchPointInCell = nil
    resetTallBubbleInnerContentAnimation()
    clipsToBounds = false
    contentView.clipsToBounds = false
    VoiceBubblePlaybackCoordinator.shared.unbind(cell: self)
    bubbleView.clearAgentStyle()
    tailView.clearAgentTailStyle()
    onVoiceBubbleTap = nil
    onVoiceUploadCancelTap = nil
    onInlineAttachmentTap = nil
    onMediaNaturalSizeResolved = nil
    onMediaGridTileTap = nil
    onRetryMessageTap = nil
    onNotSentTap = nil
    onAgentErrorRetryTap = nil
    onAgentAction = nil
    onSelectionToggle = nil
    onVideoNotePlaybackEnded = nil
    row = nil
    selectionMode = false
    isSelectionChecked = false
    cachedLayoutMetrics = nil
    // A day separator faded by the pinned date pill must not stay invisible when the
    // cell is recycled for a DIFFERENT day row — that painted as a random empty gap
    // in the list (the separator row was there, its label just had alpha 0).
    dayLabel.alpha = 1.0
    // Clear group decoration so a reused group cell doesn't keep a stale gutter
    // when dequeued for a DM (or the reverse: DM→group without reconfigure).
    groupExtraLeading = 0.0
    groupNameReservedHeight = 0.0
    groupTopReservedSpacing = 0.0
    replyAccentColors = nil
    groupSenderNameLabel.text = nil
    groupSenderNameLabel.isHidden = true
    groupSenderNameLabel.frame = .zero
    forwardedFromHeader.prepareForReuse()
    forwardedFromHeader.isHidden = true
    forwardedFromHeader.frame = .zero
    isGhostHidden = false
    mediaProgressSpinner.stopAnimating()
    mediaProgressOverlayView.isHidden = true
    mediaProgressOverlayView.alpha = 1
    mediaProgressOverlayView.transform = .identity
    mediaTransferChromeShown = false
    mediaVideoHasCompletedOnce = false
    mediaVideoUserPaused = false
    mediaProgressRingView.setUploadState(isUploading: false, progress: nil)
    mediaProgressRingView.setDownloadState(needsDownload: false, isDownloading: false, progress: nil)
    mediaProgressSizeLabel.isHidden = true
    mediaProgressSizeLabel.text = nil
    richTextView.reset()
    richTextView.isHidden = true
    resetAgentTurnContent()
    _agentTurnContentView?.isHidden = true
    _agentTurnContentView?.alpha = 1.0
    replyPreviewView.reset()
    replyPreviewView.isHidden = true
    _linkPreviewView?.reset()
    _linkPreviewView?.isHidden = true
    mediaVideoInfoBadgeView.isHidden = true
    mediaVideoAudioIconView.isHidden = true
    mediaVideoAudioIconView.image = nil
    mediaNeedsDownload = false
    mediaIsDownloading = false
    mediaDownloadProgress = nil
    mediaDownloadedBytes = nil
    mediaTotalDownloadBytes = nil
    mediaVideoCurrentTime = 0.0
    mediaVideoTotalDuration = nil
    skipRemoteMediaLoad = false
    preferredLocalMediaURLOverride = nil
    wallpaperCoordinateView = nil
    wallpaperBackdropSnapshot = nil
    wallpaperBackdropContainerSize = .zero
    bubbleView.applyWallpaperBackdrop(snapshot: nil, containerSize: .zero, sampleRect: .zero)
    tailView.applyWallpaperBackdrop(snapshot: nil, containerSize: .zero, sampleRect: .zero)
    reactionStripView.isHidden = true
    selectionCircleView.isHidden = true
    externalVoiceMessageId = nil
    externalVoiceIsPlaying = false
    externalVoiceProgress = 0.0
    lastReportedMediaSizeKey = nil
    resolveDisplayStatus = nil
    mediaVoiceButtonView.resetDownloadChromeForReuse()
    mediaNeedsDownload = false
    mediaIsDownloading = false
    mediaDownloadProgress = nil
    mediaDownloadedBytes = nil
    mediaTotalDownloadBytes = nil
    applyVoicePlaybackState(isPlaying: false, progress: 0.0, level: 0.0)
    mediaWaveformView.setWaveform(nil)
    statusImageView.isHidden = true
    statusImageView.image = nil
    pendingStatusView.isHidden = true
    statusLabel.isHidden = true
    statusLabel.text = nil
    retryButton.isHidden = true
    agentRegenerateButton.isHidden = true
    agentViewButton.isHidden = true
    notSentIndicator.isHidden = true
    notSentIndicator.transform = .identity
    notSentIndicator.alpha = 1.0
    notSentIndicatorShown = false
    _agentActionBarView?.isHidden = true
    renderedStatusKey = nil
    renderedStatusGlyph = nil
    isContextMenuExtracted = false
    isContextMenuHeld = false
    if videoNoteScaleInFlight {
      endVideoNoteScale()
    }
    hasSavedExtractionState = false
    mediaImageTask?.cancel()
    mediaImageTask = nil
    mediaImageTaskKey = nil
    mediaDecodeInFlightKey = nil
    mediaVideoUserInitiatedPlay = false
    musicCoverTask?.cancel()
    musicCoverTask = nil
    mediaImageView.image = nil
    mediaVoiceButtonView.setArtworkImage(nil)
    mediaPixelQuality = .none
    mediaContainerView.transform = .identity
    bubbleView.transform = .identity
    tailView.transform = .identity
    metaContainerView.transform = .identity
    setMediaPlaceholderHidden(true)
    _viewOnceShineCover?.setActive(false)
    _viewOnceShineCover?.isHidden = true
    lastReactionDebugSignature = nil
    applyContextMenuExtractionIfNeeded()
    applyContextMenuHoldIfNeeded(animated: false, strategy: "scaleCell")
    contentView.alpha = 1.0
    contentView.transform = .identity
    messageLabel.resetStreamingState()
    let superStartedAt = ProcessInfo.processInfo.systemUptime
    super.prepareForReuse()
    let finishedAt = ProcessInfo.processInfo.systemUptime
    let totalMs = (finishedAt - reuseStartedAt) * 1_000.0
    if totalMs > 8.0 {
      NSLog(
        "[CellCost] prepareForReuse total=%.1fms super=%.1fms",
        totalMs, (finishedAt - superStartedAt) * 1_000.0)
    }
  }

  /// Always clear the reconfigure gate alongside a body reset: after `reset()` the body
  /// renders NOTHING, so a "row unchanged → skip configure" decision would leave the
  /// bubble permanently empty when the same row becomes visible again.
  private func resetAgentTurnContent() {
    _agentTurnContentView?.reset()
    lastAgentTurnConfiguredRow = nil
    lastAgentTurnConfiguredWidth = -1.0
    lastAgentTurnConfiguredState = nil
    lastAgentTurnConfiguredStyle = .unspecified
  }

  @objc private func agentComputerBandTapped() {
    guard let messageId = row?.messageId else { return }
    onAgentAction?(["type": "openAgentComputer", "messageId": messageId])
  }

  private func startTypingShimmer() {
    stopTypingShimmer()  // Clear any existing
    let gradientLayer = CAGradientLayer()
    gradientLayer.colors = [
      UIColor.white.withAlphaComponent(0.4).cgColor,
      UIColor.white.withAlphaComponent(1.0).cgColor,
      UIColor.white.withAlphaComponent(0.4).cgColor,
    ]
    gradientLayer.locations = [0.0, 0.5, 1.0]
    gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
    gradientLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
    // We update the frame after layout in layoutSubviews, but for now set a placeholder
    gradientLayer.frame = CGRect(x: -200, y: 0, width: 600, height: 40)
    messageLabel.layer.mask = gradientLayer

    let animation = CABasicAnimation(keyPath: "transform.translation.x")
    animation.fromValue = -200
    animation.toValue = 200
    animation.duration = 1.5
    animation.repeatCount = .infinity
    animation.isRemovedOnCompletion = false

    gradientLayer.add(animation, forKey: "shimmerTranslation")
  }

  private func stopTypingShimmer() {
    messageLabel.layer.mask?.removeAnimation(forKey: "shimmerTranslation")
    messageLabel.layer.mask = nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let row else {
      return
    }

    // Tall-content: outer glass chip is list-hosted. Track id for the host anchor.
    tallToggleRowMessageId = row.messageId ?? row.key
    lastTallToggleVisible = false
    lastTallCollapsed = false
    lastBubbleFrame = .zero
    messageLabel.numberOfLines = 0
    messageLabel.clipsToBounds = false
    richTextView.clipsToBounds = false
    // Agent turns: ALWAYS clip. A stale layout height (common after live→settle or
    // bridge-restart history upsert) must never paint the body over the next cell.
    _agentTurnContentView?.clipsToBounds = true
    // Only the agent-turn arm below re-shows the computer band; every other path leaves it off.
    _agentComputerBandView?.isHidden = true
    _agentComputerBandView?.frame = .zero
    // Only the decision arm below re-shows the approval card.
    _serviceDecisionCardView?.isHidden = true
    _serviceDecisionCardView?.frame = .zero

    let bounds = contentView.bounds
    if row.kind == .day || isConfiguredAgentDivider {
      let actionsHeight = isConfiguredServiceDecision ? serviceDecisionActionsHeight(for: row) : 0
      let textSize = dayLabel.sizeThatFits(CGSize(width: bounds.width - 16, height: 24))
      let width = min(bounds.width - 8, ceil(textSize.width) + (dayPillHorizontalPadding * 2.0))
      let height = ceil(textSize.height) + (dayPillVerticalPadding * 2.0)
      let totalBlock = height + actionsHeight
      let top = floor((bounds.height - totalBlock) * 0.5)
      dayLabel.frame = CGRect(
        x: floor((bounds.width - width) * 0.5),
        y: top,
        width: width,
        height: height
      )
      dayLabel.layer.cornerRadius = height / 2.0
      if isConfiguredServiceDecision {
        let cardHeight = ChatServiceDecisionCardView.height(
          risk: serviceDecisionRisk(for: row), detail: serviceDecisionDetailText(for: row))
        let blockWidth = max(1, bounds.width - 24)
        if cardHeight > 0 {
          let card = serviceDecisionCardView
          card.frame = CGRect(
            x: 12, y: dayLabel.frame.maxY + 4, width: blockWidth, height: cardHeight)
          card.isHidden = false
        }
        serviceActionBarView.frame = CGRect(
          x: 12,
          y: dayLabel.frame.maxY + 4 + cardHeight,
          width: blockWidth,
          height: max(0, actionsHeight - cardHeight - 4)
        )
        serviceActionBarView.isHidden = false
      } else {
        serviceActionBarView.frame = .zero
        serviceActionBarView.isHidden = true
      }
      return
    }

    if row.messageType == "agent_actions" {
      _agentTurnContentView?.frame = .zero
      // Selection chrome only opens space on the leading edge for *them* rows.
      // "Me" bubbles stay trailing-pinned — no whole-list shift.
      let selectionInset =
        (selectionMode && !row.isMe) ? messageSelectionLeadingInset : 0.0
      let layoutWidth = max(1.0, bounds.width)
      agentActionBarView.frame = pixelAlignedRect(
        CGRect(
          x: bubbleSideMargin + selectionInset,
          y: max(0.0, bounds.height - 36.0),
          width: max(1.0, layoutWidth - (bubbleSideMargin * 2.0) - selectionInset),
          height: 36.0
        )
      )
      _agentTurnContentView?.frame = .zero
      return
    }

    // Only incoming ("them") bubbles slide right for the check circle.
    // Outgoing ("me") stay fixed on the trailing edge — no list-wide push.
    let selectionInset =
      (selectionMode && !row.isMe) ? messageSelectionLeadingInset : 0.0
    // Incoming group messages reserve a leading avatar gutter: measure the bubble against
    // the narrowed width and shift it right by the same amount, so it never sits under the
    // floating avatar. Outgoing / DM rows keep groupExtraLeading == 0 (no change).
    let layoutWidth = max(1.0, bounds.width - groupExtraLeading)
    let metrics: ChatMessageBubbleLayoutMetrics
    if let cached = cachedLayoutMetrics, cachedLayoutWidth == layoutWidth, !cached.usesRichTextLayout {
      metrics = cached
    } else {
      metrics = measureMessageBubbleLayout(
        row: row, rowWidth: layoutWidth, agentTurnState: agentTurnState
      )
      cachedLayoutMetrics = metrics
      cachedLayoutWidth = layoutWidth
    }
    let bubbleWidth = metrics.bubbleWidth
    // While the list animates a tall expand/collapse, the cell bounds interpolate
    // between collapsed and full height. Track that intermediate height so the plate
    // morphs instead of snapping to the target metrics size (empty gap / overflow jump).
    // Top-corner glass chip is overlay-only and does not reserve cell height.
    let outerReserve = metrics.tallOuterToggleReserve
    // Top chrome (group name / forward header). When present, TOP-ALIGN the stack so
    // reopen / seed-height corrections cannot bottom-pin content under empty air and
    // then paint the header over it (the reported shift + overlap).
    let inBubbleNameReserve = groupNameReservedHeight > 0.5 ? groupNameReservedHeight : 0.0
    let topAir = groupTopReservedSpacing
    let availableBubbleHeight = max(
      1.0, bounds.height - inBubbleNameReserve - topAir - outerReserve)
    let isTallHeightMorphing =
      metrics.tallToggleVisible && abs(availableBubbleHeight - metrics.bubbleHeight) > 1.0
    let isVideoNoteScaling =
      row.visualKind == .videoNote && abs(availableBubbleHeight - metrics.bubbleHeight) > 1.0
    // Always clamp to the slot under chrome so a short cell never lets body text
    // run into the forward header or the next row.
    let bubbleHeight: CGFloat = {
      if isVideoNoteScaling { return metrics.bubbleHeight }
      let raw = isTallHeightMorphing ? availableBubbleHeight : metrics.bubbleHeight
      return min(raw, availableBubbleHeight)
    }()
    // The slot the layout granted vs the bubble this configure actually renders. Both
    // come from the SAME `measureMessageBubbleLayout`, so any disagreement means the slot
    // was served from a CACHED height that no longer describes this row — and both signs
    // are visible defects, because the bubble is bottom-pinned inside the slot:
    //   • slot too SHORT — the plate is clamped, but the caption/meta below the media are
    //     placed from the full metrics, so they paint outside the bubble.
    //   • slot too TALL — the plate is correct and the excess becomes empty air ABOVE it.
    //     This is the large gap that appears when a message with an image arrives: the row
    //     is inserted before the image is known, sized by the square fallback, and the
    //     resolved natural size never invalidated the cached height.
    // Neither is catchable upstream — `auditSeedTrustedHeights` re-checks row CONTENT,
    // and in both cases the content is identical. Report it so the host re-measures.
    let slotSlack = availableBubbleHeight - metrics.bubbleHeight
    // A streaming turn is EXPECTED to disagree with its slot between chunks — that is the
    // normal reload cadence, not a stale height — and it clips its own body, so it can
    // never paint outside the plate. Reporting it would only add a redundant reload to
    // the row whose cell must survive in place.
    let slotGeometryIsStable =
      !isTallHeightMorphing && !isVideoNoteScaling && !metrics.tallToggleVisible
      && !row.isStreamingText
      && !isContextMenuExtracted && !isContextMenuHeld && superview != nil
    let slotIsTooShort = slotSlack < -0.5 && slotGeometryIsStable
    // Asymmetric threshold: a short slot is a hard defect at any size (text lands outside
    // the plate), while a tall slot only reads as a gap once it is worth a glance — and a
    // point or two of slack is ordinary rounding between two measurement passes.
    let slotIsTooTall = slotSlack > 8.0 && slotGeometryIsStable
    if slotIsTooShort || slotIsTooTall {
      onSlotHeightMismatch?(row.key, slotSlack)
    }
    let videoNoteExpandedCentered =
      row.visualKind == .videoNote && agentTurnState.videoNoteExpanded
    let bubbleX: CGFloat
    if videoNoteExpandedCentered {
      bubbleX = max(bubbleSideMargin, (layoutWidth - bubbleWidth) / 2.0)
    } else if metrics.agentTurnCentered {
      // Compact "thinking" pill: center it in the row instead of pinning to the leading
      // edge, so the tiny loader reads as a centered indicator rather than a marooned
      // scrap in a full-width shell. Selection inset only shifts non-me rows.
      bubbleX =
        max(bubbleSideMargin, (layoutWidth - bubbleWidth) / 2.0)
        + selectionInset + groupExtraLeading
    } else if row.isMe {
      // Trailing-pinned: never apply selection leading inset (no push-to-right).
      // Video notes: meta (time + ticks) now sits INSIDE the circle bottom-right
      // (Telegram-authentic overlay pill), so no trailing reserve is needed here.
      bubbleX =
        layoutWidth - bubbleWidth - bubbleSideMargin
    } else {
      bubbleX = bubbleSideMargin + groupExtraLeading + selectionInset
    }
    // With chrome: content starts right under the reserved strip (stable top stack).
    // Without chrome: keep classic bottom-pin so tails align with neighbouring cells.
    let bubbleY: CGFloat
    if inBubbleNameReserve > 0.5 {
      bubbleY = topAir + inBubbleNameReserve
    } else {
      bubbleY = max(0.0, bounds.height - bubbleHeight - outerReserve)
    }
    let bubbleFrame = pixelAlignedRect(
      CGRect(
        x: floor(bubbleX),
        y: floor(bubbleY),
        width: ceil(bubbleWidth),
        height: ceil(bubbleHeight)
      ))
    // Plate wraps chrome + body. Chrome lives in [plate.minY, bubbleFrame.minY).
    let bubblePlateFrame: CGRect
    if inBubbleNameReserve > 0.5 {
      bubblePlateFrame = pixelAlignedRect(
        CGRect(
          x: bubbleFrame.minX,
          y: topAir,
          width: bubbleFrame.width,
          height: bubbleFrame.height + inBubbleNameReserve
        ))
    } else {
      bubblePlateFrame = bubbleFrame
    }
    lastBubbleFrame = bubblePlateFrame
    lastTallToggleVisible = metrics.tallToggleVisible
    lastTallCollapsed = metrics.tallCollapsed
    // Names the cell-vs-bubble disagreement behind "bubbles overlap the next cell":
    // the slot the layout granted vs the height this configure actually renders.
    if bubbleFrame.maxY > bounds.height + 2.0 {
      NSLog(
        "[CellFit] OVERFLOW key=%@ cellH=%.0f bubbleH=%.0f overflow=%.0f rtl=%@ bottomMeta=%@ w=%.0f",
        String(row.key.suffix(14)), bounds.height, metrics.bubbleHeight,
        bubbleFrame.maxY - bounds.height,
        usesRTLColumnLayout(row) ? "Y" : "N",
        metrics.usesBottomMetaLayout ? "Y" : "N", layoutWidth)
    }

    // Tall rows clip overflow so full content under a short plate doesn't paint the next
    // cell. Soft fade mask on the body communicates "more below" (not a hard cut).
    // Forwarded / named rows also clip so chrome↔body seams never bleed into neighbours
    // when a reopen uses a slightly-short seed height for one frame.
    if isVideoNoteScaling || videoNoteScaleInFlight {
      clipsToBounds = false
      contentView.clipsToBounds = false
    } else if metrics.tallToggleVisible || inBubbleNameReserve > 0.5 || slotIsTooShort {
      clipsToBounds = true
      contentView.clipsToBounds = true
    } else {
      clipsToBounds = false
      contentView.clipsToBounds = false
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    bubbleView.frame = bubblePlateFrame

    // Top-of-plate chrome stack — fills EXACTLY the reserved strip so body at
    // bubbleFrame.minY cannot overlap it:
    //   [optional group sender name]
    //   [optional Forwarded from / avatar / name]
    // Telegram keeps ~2–4pt between name and body (not a large empty band).
    let chromeX = bubblePlateFrame.minX + bubbleHorizontalPadding
    let chromeMaxX = min(
      bubblePlateFrame.maxX - bubbleHorizontalPadding, bounds.width - bubbleSideMargin)
    let chromeWidth = max(0.0, chromeMaxX - chromeX)
    let chromeTop = bubblePlateFrame.minY
    let chromeBottom = bubbleFrame.minY
    if !groupSenderNameLabel.isHidden {
      let nameH: CGFloat = 15.0
      let nameY = chromeTop + 2.0
      let maxNameH = max(0.0, chromeBottom - nameY - 1.0)
      groupSenderNameLabel.frame = pixelAlignedRect(
        CGRect(
          x: chromeX, y: nameY, width: chromeWidth,
          height: min(nameH, maxNameH)))
    } else {
      groupSenderNameLabel.frame = .zero
    }
    if !forwardedFromHeader.isHidden {
      // Forward-only: fill the whole reserved strip. With a group name above, take
      // whatever is left under the name so body at chromeBottom never overlaps.
      let forwardY: CGFloat
      if !groupSenderNameLabel.isHidden {
        forwardY = groupSenderNameLabel.frame.maxY + 3.0
      } else {
        forwardY = chromeTop
      }
      let forwardH = max(0.0, chromeBottom - forwardY)
      forwardedFromHeader.frame = pixelAlignedRect(
        CGRect(
          x: chromeX,
          y: forwardY,
          width: chromeWidth,
          height: forwardH
        ))
      // Keep chrome above the plate fill / body subviews so text never paints over it.
      contentView.bringSubviewToFront(groupSenderNameLabel)
      contentView.bringSubviewToFront(forwardedFromHeader)
    } else {
      forwardedFromHeader.frame = .zero
    }
    // Telegram-tight: body starts almost immediately under the forward header.
    let selectionSize: CGFloat = 26.0
    selectionCircleView.frame = pixelAlignedRect(
      CGRect(
        x: 2.0,
        y: max(0.0, bubbleFrame.midY - selectionSize * 0.5),
        width: selectionSize,
        height: selectionSize
      ))
    let isTransparentSticker = isTransparentStickerMessage(row)
    let usesTransparentAgentStreaming = usesTransparentAgentStreamingLayout(row)
    let isFullBleed = metrics.isMediaLayout && usesFullBleedMediaLayout(row)
    let metaTopSpacing = effectiveMetaTopSpacing(for: row)

    // NOTE: ghost-hidden rows keep their TRUE tail geometry — visibility is
    // handled entirely by the hidden flags in configure(). Stripping the tail
    // from the hidden bubble's path made the send-morph reveal a structural
    // path swap (tail-less silhouette → tailed) at the exact landing frame,
    // seen as "the tail appears after the bubble is in the list".
    // Video notes are pure circles — never show a bubble tail (Telegram).
    let showTail = row.shape.showTail && !metrics.agentTurnCentered
      && row.visualKind != .videoNote
      && !(row.messageType == "typing" || isTransparentStickerMessage(row) || usesTransparentAgentStreaming)
    // Normal bubbles draw the tail INSIDE BubbleBackgroundView's own path (one shape, one
    // fill — no color seam, no sliver outside the corner curve). The separate rotated
    // tailView remains only for full-bleed media, where the tail must show image content.
    bubbleView.setIntegratedTailEnabled(showTail && !isFullBleed)
    if showTail && isFullBleed {
      // IMPORTANT: tailView has a rotation+flip transform applied, so we MUST NOT
      // set .frame (undefined behavior per Apple docs). Use bounds + center instead.
      let tailSize: CGFloat = 29
      let tailX = row.isMe ? bubbleFrame.maxX - 1.0 : bubbleFrame.minX - tailSize + 1.0
      let tailY = bubbleFrame.maxY - tailSize + 3.0
      tailView.bounds = CGRect(origin: .zero, size: CGSize(width: tailSize, height: tailSize))
      tailView.center = CGPoint(x: tailX + tailSize * 0.5, y: tailY + tailSize * 0.5)
      let img = mediaImageView.image
      tailView.setImage(img)
      // Hide tail until media image loads to avoid bubble-colored tail flash.
      // Ghost rows: unlike the integrated tail (part of an already-hidden
      // bubble's path), this is a standalone view — it must stay hidden.
      tailView.isHidden = img == nil || isGhostHidden
    } else {
      tailView.setImage(nil)
      tailView.isHidden = true
    }

    if metrics.isMediaLayout {
      let hasMediaCaption = hasMediaCaptionLayout(row) && metrics.textHeight > 0.0 && !isFullBleed
      _agentTurnContentView?.frame = .zero
      richTextView.frame = .zero
      replyPreviewView.frame = .zero
      _linkPreviewView?.frame = .zero
      let mediaFrame: CGRect
      if isFullBleed, row.visualKind == .videoNote {
        let metaBlock = metaTopSpacing + bubbleMetaHeight
        let side = min(
          bubbleFrame.width,
          metrics.mediaHeight,
          max(1.0, bubbleFrame.height - metaBlock))
        let x = row.isMe ? bubbleFrame.maxX - side : bubbleFrame.minX
        mediaFrame = pixelAlignedRect(
          CGRect(x: x, y: bubbleFrame.minY, width: side, height: side))
      } else if isFullBleed {
        mediaFrame = pixelAlignedRect(bubbleFrame.insetBy(dx: -0.6, dy: -0.6))
      } else if isTransparentSticker {
        let mediaX = row.isMe ? (bubbleFrame.maxX - metrics.contentWidth) : bubbleFrame.minX
        mediaFrame = pixelAlignedRect(
          CGRect(
            x: mediaX,
            y: bubbleFrame.minY,
            width: metrics.contentWidth,
            height: metrics.mediaHeight
          ))
      } else if usesEdgeMediaCaptionLayout(row) {
        // Edge-to-edge media above the caption: hairline inset on all media sides.
        mediaFrame = pixelAlignedRect(
          CGRect(
            x: bubbleFrame.minX + mediaCaptionEdgeInset,
            y: bubbleFrame.minY + mediaCaptionEdgeInset,
            width: bubbleFrame.width - mediaCaptionEdgeInset * 2.0,
            height: metrics.mediaHeight
          ))
      } else {
        let mediaTopInset: CGFloat =
          row.visualKind == .voice ? 2.0 : bubbleTopPadding
        let mediaLeftInset: CGFloat =
          row.visualKind == .voice
          ? max(6.0, bubbleHorizontalPadding - 2.0) : bubbleHorizontalPadding
        mediaFrame = pixelAlignedRect(
          CGRect(
            x: bubbleFrame.minX + mediaLeftInset,
            y: bubbleFrame.minY + mediaTopInset,
            width: metrics.contentWidth,
            height: metrics.mediaHeight
          ))
      }
      mediaContainerView.frame = mediaFrame
      if let r = self.row, r.visualKind != .text && r.visualKind != .voice {
        chatCellDebugLog(
          chatCellMediaDebugLogs,
          "[ChatMediaLayout] msgId=%@ containerFrame=%@ hidden=%@ alpha=%.2f imgHidden=%@ hasImg=%@ bubbleFrame=%@",
          r.messageId ?? "-",
          NSCoder.string(for: mediaFrame),
          mediaContainerView.isHidden ? "Y" : "N",
          mediaContainerView.alpha,
          mediaImageView.isHidden ? "Y" : "N",
          mediaImageView.image != nil ? "Y" : "N",
          NSCoder.string(for: bubbleFrame)
        )
      }

      if hasMediaCaption {
        messageLabel.frame = pixelAlignedRect(
          CGRect(
            x: bubbleFrame.minX + bubbleHorizontalPadding,
            y: mediaFrame.maxY + (usesEdgeMediaCaptionLayout(row) ? mediaCaptionTopGap : 8.0),
            width: metrics.messageWidth,
            height: metrics.textHeight
          ))
      } else {
        messageLabel.frame = .zero
      }
      let metaX: CGFloat
      let metaY: CGFloat
      let usesViewOnceMetaPlate =
        row.viewOnce && isFullBleed && row.visualKind != .videoNote
      if row.visualKind == .videoNote {
        // Telegram: time + ✓ sit on the wallpaper UNDER the circle, bottom-right — the
        // circular clip cuts anything parented inside it.
        if metaContainerView.superview !== contentView {
          contentView.addSubview(metaContainerView)
        }
        metaContainerView.layer.cornerRadius = 0
        metaX = mediaFrame.maxX - metrics.metaWidth - 6.0
        metaY = mediaFrame.maxY + metaTopSpacing
      } else {
        if metaContainerView.superview !== contentView {
          contentView.addSubview(metaContainerView)
        }
        metaContainerView.layer.cornerRadius =
          usesViewOnceMetaPlate ? (bubbleMetaHeight + 4.0) * 0.5 : 0
        if isFullBleed {
          metaX = bubbleFrame.maxX - metrics.metaWidth - 10
          metaY = bubbleFrame.maxY - bubbleMetaHeight - 8
        } else if isTransparentSticker {
          metaX = bubbleFrame.maxX - metrics.metaWidth
          metaY = mediaFrame.maxY + metaTopSpacing
        } else if row.visualKind == .voice {
          metaX = bubbleFrame.maxX - bubbleHorizontalPadding - metrics.metaWidth
          metaY = bubbleFrame.maxY - bubbleMetaHeight - 3.0
        } else if hasMediaCaption {
          metaX = bubbleFrame.maxX - bubbleHorizontalPadding - metrics.metaWidth
          metaY = messageLabel.frame.maxY + bubbleMetaTopSpacing
        } else {
          metaX = bubbleFrame.maxX - bubbleHorizontalPadding - metrics.metaWidth
          metaY = mediaFrame.maxY + metaTopSpacing
        }
      }

      let metaInsetX: CGFloat = usesViewOnceMetaPlate ? 6.0 : 0.0
      let metaInsetY: CGFloat = usesViewOnceMetaPlate ? 2.0 : 0.0
      metaContainerView.frame = pixelAlignedRect(
        CGRect(
          x: metaX - metaInsetX,
          y: metaY - metaInsetY,
          width: metrics.metaWidth + metaInsetX * 2.0,
          height: bubbleMetaHeight + metaInsetY * 2.0
        ))

      mediaProgressOverlayView.frame = mediaContainerView.bounds
      mediaImageView.frame = mediaContainerView.bounds
      _mediaStickerAnimationView?.frame = mediaContainerView.bounds
      layoutMediaSubviews(for: row, in: mediaContainerView.bounds)
      inlineAttachmentView.frame = .zero
      clearTallCollapseFadeMask(on: messageLabel)
      clearTallCollapseFadeMask(on: richTextView)
      _agentTurnContentView.map { clearTallCollapseFadeMask(on: $0) }
    } else {
      mediaContainerView.frame = .zero
      let bubbleTextColor = row.isMe ? appearance.textColorMe : appearance.textColorThem
      if bubbleUsesAgentTurnContent(row) {
        richTextView.frame = .zero
        messageLabel.frame = .zero
        clearTallCollapseFadeMask(on: messageLabel)
        clearTallCollapseFadeMask(on: richTextView)
        replyPreviewView.frame = .zero
        _linkPreviewView?.frame = .zero
        inlineAttachmentView.frame = .zero
        metaContainerView.frame = .zero
        // Match the tighter agent-turn insets used by measureMessageBubbleLayout so the
        // content frame lines up with the measured bubble height.
        let contentX = bubbleFrame.minX + agentTurnHorizontalPadding
        let contentY = bubbleFrame.minY + agentTurnVerticalPadding
        let interfaceStyle = traitCollection.userInterfaceStyle
        let bodyInputsUnchanged =
          lastAgentTurnConfiguredWidth == metrics.messageWidth
          && lastAgentTurnConfiguredState == agentTurnState
          && lastAgentTurnConfiguredStyle == interfaceStyle
          && lastAgentTurnConfiguredRow.map { chatListRowContentEqual($0, row) } == true
        if !bodyInputsUnchanged {
          agentTurnContentView.configure(
            row: row,
            appearance: VibeAgentKitMap.appearance(for: traitCollection),
            availableWidth: metrics.messageWidth,
            isProgressExpanded: agentTurnState.isProgressExpanded,
            isRuntimeExpanded: agentTurnState.isRuntimeExpanded,
            expandedStepIds: agentTurnState.expandedStepIds,
            streamingStartDate: agentTurnState.streamingStartDate,
            onLoaderTap: { [weak self] in
              guard let self, let messageId = row.messageId else { return }
              // Tapping the "Working / Worked for…" header opens the full turn in the glass
              // sheet (same renderer) rather than an inline expand — see presentAgentTurnDetailView.
              self.onAgentAction?(["type": "openAgentTurnDetail", "messageId": messageId])
            },
            showsLoaderView: agentTurnBubbleShowsWorkedSummary(row),
            // Keep full multi-block layout always — collapse is plate height + soft mask
            // only (no content swap / no expand fade).
            isContentCollapsed: false
          )
          lastAgentTurnConfiguredRow = row
          lastAgentTurnConfiguredWidth = metrics.messageWidth
          lastAgentTurnConfiguredState = agentTurnState
          lastAgentTurnConfiguredStyle = interfaceStyle
        }
        // Prefer fitting the morphing plate: when the cell is mid expand/collapse the
        // available body height is the interpolating bubble, not the settled metrics.
        let computerBand = agentTurnComputerBandState(row)
        let computerBandReserve = agentTurnComputerBandReserve(row)
        let agentBodyMaxHeight = max(
          1.0,
          bubbleFrame.height - (agentTurnVerticalPadding * 2.0) - computerBandReserve
        )
        // Frame height = visible plate slice; full content is measured taller and soft-
        // masked when collapsed so expand only grows Y.
        // A live stream can receive its next body measurement one run-loop before the
        // collection layout installs the matching taller slot. Never give the wrapper a
        // frame outside the plate during that interval: the next invalidated layout reveals
        // the remaining text at its newly measured height, while this pass stays contained.
        let agentBodyHeight = min(metrics.textHeight, agentBodyMaxHeight)
        agentTurnContentView.frame = pixelAlignedRect(
          CGRect(
            x: contentX,
            y: contentY,
            width: metrics.messageWidth,
            height: agentBodyHeight
          )
        )
        let agentNeedsFade =
          metrics.tallToggleVisible
          && (metrics.tallCollapsed || isTallHeightMorphing)
          && metrics.textHeight > agentBodyHeight + 1.0
        applyTallCollapseFadeMask(to: agentTurnContentView, enabled: agentNeedsFade)
        if let computerBand {
          let band = agentComputerBandView
          band.isHidden = false
          band.configure(
            isShell: computerBand.isShell, primary: computerBand.primary,
            secondary: computerBand.secondary, live: computerBand.live,
            showsTakeControl: computerBand.showsTakeControl,
            appearance: VibeAgentKitMap.appearance(for: traitCollection))
          band.frame = pixelAlignedRect(
            CGRect(
              x: contentX,
              y: agentTurnContentView.frame.maxY + agentTurnComputerBandTopGap,
              width: metrics.messageWidth,
              height: agentTurnComputerBandHeight
            ))
        }

      } else if metrics.hasInlineAttachment {
        _agentTurnContentView?.frame = .zero
        richTextView.frame = .zero
        clearTallCollapseFadeMask(on: messageLabel)
        clearTallCollapseFadeMask(on: richTextView)
        _agentTurnContentView.map { clearTallCollapseFadeMask(on: $0) }
        _linkPreviewView?.frame = .zero
        let contentX = bubbleFrame.minX + bubbleHorizontalPadding
        var contentY = bubbleFrame.minY + bubbleTopPadding
        if metrics.hasReplyPreview {
          replyPreviewView.frame = pixelAlignedRect(
            CGRect(
              x: contentX,
              y: contentY,
              width: metrics.contentWidth,
              height: metrics.replyPreviewHeight
            ))
          contentY = replyPreviewView.frame.maxY + bubbleReplyPreviewSpacing
        } else {
          replyPreviewView.frame = .zero
        }
        messageLabel.frame = pixelAlignedRect(
          CGRect(
            x: contentX,
            y: contentY,
            width: metrics.messageWidth,
            height: metrics.textHeight
          ))
        inlineAttachmentView.frame = pixelAlignedRect(
          CGRect(
            x: contentX,
            y: messageLabel.frame.maxY + inlineAttachmentSpacing,
            width: metrics.contentWidth,
            height: metrics.inlineAttachmentHeight
          ))
        metaContainerView.frame = pixelAlignedRect(
          CGRect(
            x: bubbleFrame.maxX - bubbleHorizontalPadding - metrics.metaWidth,
            y: inlineAttachmentView.frame.maxY + bubbleMetaTopSpacing,
            width: metrics.metaWidth,
            height: bubbleMetaHeight
          ))

        let iconSize: CGFloat = 18.0
        inlineAttachmentIconView.frame = CGRect(x: 12.0, y: 15.0, width: iconSize, height: iconSize)
        inlineAttachmentTitleLabel.frame = CGRect(
          x: inlineAttachmentIconView.frame.maxX + 10.0,
          y: 8.0,
          width: max(
            1.0, inlineAttachmentView.bounds.width - inlineAttachmentIconView.frame.maxX - 22.0),
          height: 18.0
        )
        inlineAttachmentSubtitleLabel.frame = CGRect(
          x: inlineAttachmentTitleLabel.frame.minX,
          y: inlineAttachmentTitleLabel.frame.maxY + 1.0,
          width: inlineAttachmentTitleLabel.frame.width,
          height: 15.0
        )
      } else if metrics.usesBottomMetaLayout {
        _agentTurnContentView?.frame = .zero
        let contentX = bubbleFrame.minX + bubbleHorizontalPadding
        var contentY = bubbleFrame.minY + bubbleTopPadding

        inlineAttachmentView.frame = .zero
        if metrics.hasReplyPreview {
          replyPreviewView.frame = pixelAlignedRect(
            CGRect(
              x: contentX,
              y: contentY,
              width: metrics.contentWidth,
              height: metrics.replyPreviewHeight
            ))
          contentY = replyPreviewView.frame.maxY + bubbleReplyPreviewSpacing
        } else {
          replyPreviewView.frame = .zero
        }
        _agentTurnContentView.map { clearTallCollapseFadeMask(on: $0) }
        // Visible body height inside the (possibly morphing) plate — full text is taller
        // when collapsed; soft mask fades the cut instead of hard-clipping glyphs.
        let textBodyMaxHeight: CGFloat = {
          guard metrics.tallToggleVisible else { return metrics.textHeight }
          let metaAndPreview =
            (metrics.hasLinkPreview ? bubbleLinkPreviewSpacing + metrics.previewHeight : 0.0)
            + bubbleMetaTopSpacing + bubbleMetaHeight
          return max(
            1.0,
            bubbleFrame.height - bubbleTopPadding - bubbleBottomPadding
              - (metrics.hasReplyPreview ? metrics.replyPreviewHeight + bubbleReplyPreviewSpacing : 0.0)
              - metaAndPreview
          )
        }()

        if metrics.usesRichTextLayout {
          messageLabel.frame = .zero
          clearTallCollapseFadeMask(on: messageLabel)
          let richTextHeight = richTextView.configure(
            row: row,
            textColor: bubbleTextColor,
            availableWidth: metrics.messageWidth
          )
          let fullRichHeight = max(metrics.textHeight, richTextHeight)
          let visibleRichHeight =
            metrics.tallToggleVisible
            ? min(fullRichHeight, textBodyMaxHeight)
            : fullRichHeight
          richTextView.clipsToBounds = metrics.tallToggleVisible
          richTextView.frame = pixelAlignedRect(
            CGRect(
              x: contentX,
              y: contentY,
              width: metrics.messageWidth,
              height: visibleRichHeight
            )
          )
          let richNeedsFade =
            metrics.tallToggleVisible
            && (metrics.tallCollapsed || isTallHeightMorphing)
            && fullRichHeight > visibleRichHeight + 1.0
          applyTallCollapseFadeMask(to: richTextView, enabled: richNeedsFade)
        } else {
          richTextView.frame = .zero
          clearTallCollapseFadeMask(on: richTextView)
          // Always unlimited lines — expand only grows the visible height.
          messageLabel.numberOfLines = 0
          let visibleTextHeight =
            metrics.tallToggleVisible
            ? min(metrics.textHeight, textBodyMaxHeight)
            : metrics.textHeight
          messageLabel.clipsToBounds = metrics.tallToggleVisible
          messageLabel.frame = pixelAlignedRect(
            CGRect(
              x: contentX,
              y: contentY,
              width: metrics.messageWidth,
              height: visibleTextHeight
            )
          )
          let textNeedsFade =
            metrics.tallToggleVisible
            && (metrics.tallCollapsed || isTallHeightMorphing)
            && metrics.textHeight > visibleTextHeight + 1.0
          applyTallCollapseFadeMask(to: messageLabel, enabled: textNeedsFade)
        }

        let textBottom = metrics.usesRichTextLayout ? richTextView.frame.maxY : messageLabel.frame.maxY

        if metrics.hasLinkPreview {
          let previewTop = textBottom + bubbleLinkPreviewSpacing
          linkPreviewView.frame = pixelAlignedRect(
            CGRect(
              x: contentX,
              y: previewTop,
              width: metrics.contentWidth,
              height: metrics.previewHeight
            )
          )
        } else {
          _linkPreviewView?.frame = .zero
        }

        let ridesReactionRow = !row.reactions.isEmpty && !metrics.hasLinkPreview
        let metaTop: CGFloat
        if ridesReactionRow {
          metaTop =
            bubbleFrame.maxY - reactionStripBottomInset - reactionChipHeight / 2.0
            - bubbleMetaHeight / 2.0
        } else if metrics.hasLinkPreview {
          metaTop = (_linkPreviewView?.frame.maxY ?? textBottom) + bubbleMetaTopSpacing
        } else {
          metaTop = textBottom + bubbleMetaTopSpacing
        }
        // Meta (time / sent) is ALWAYS trailing — RTL included. Telegram keeps the ✓ at
        // the bubble's right edge and leads the body instead; mirroring the meta to the
        // left put the two rows on opposite edges and looked misordered.
        let metaX = bubbleFrame.maxX - bubbleHorizontalPadding - metrics.metaWidth
        let metaFrame = pixelAlignedRect(
          CGRect(
            x: metaX,
            y: metaTop,
            width: metrics.metaWidth,
            height: bubbleMetaHeight
          )
        )
        metaContainerView.frame = metaFrame
      } else {
        _agentTurnContentView?.frame = .zero
        richTextView.frame = .zero
        _linkPreviewView?.frame = .zero
        inlineAttachmentView.frame = .zero

        if metrics.hasReplyPreview {
          replyPreviewView.frame = pixelAlignedRect(
            CGRect(
              x: bubbleFrame.minX + bubbleHorizontalPadding,
              y: bubbleFrame.minY + bubbleTopPadding,
              width: metrics.contentWidth,
              height: metrics.replyPreviewHeight
            ))
        } else {
          replyPreviewView.frame = .zero
        }

        messageLabel.frame = pixelAlignedRect(
          CGRect(
            x: bubbleFrame.minX + bubbleHorizontalPadding,
            y: bubbleFrame.minY + bubbleTopPadding
              + max(0.0, metrics.bodyHeight - metrics.textHeight),
            width: metrics.messageWidth,
            height: metrics.textHeight
          ))
        // With a reaction strip the plate grew by its height: keep the meta on the strip
        // row (Telegram) instead of the plate bottom, where the two collided.
        let metaBottomY =
          row.reactions.isEmpty
          ? bubbleFrame.maxY - 5.0 - bubbleMetaHeight
          : bubbleFrame.maxY - reactionStripBottomInset - reactionChipHeight / 2.0
            - bubbleMetaHeight / 2.0
        metaContainerView.frame = pixelAlignedRect(
          CGRect(
            x: bubbleFrame.maxX - 8.0 - metrics.metaWidth,
            y: metaBottomY,
            width: metrics.metaWidth,
            height: bubbleMetaHeight
          ))
      }
    }

    updateStickerAnimationPlayback()

    layoutMetaLabels(for: row)

    if row.messageType == "typing" || row.messageType == "agent_progress_tree" {
      if let mask = messageLabel.layer.mask as? CAGradientLayer {
        mask.frame = CGRect(
          x: -messageLabel.bounds.width * 2, y: 0, width: messageLabel.bounds.width * 5,
          height: messageLabel.bounds.height)
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = -messageLabel.bounds.width * 2
        animation.toValue = messageLabel.bounds.width * 2
        animation.duration = 1.5
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        mask.add(animation, forKey: "shimmerTranslation")
      }
    }

    let metaRidesReactionRow =
      !row.reactions.isEmpty && !metrics.hasInlineAttachment
      && !metrics.isMediaLayout && !metrics.hasLinkPreview
    let reactionFrame = pixelAlignedRect(
      reactionBadgeFrame(
        in: bubbleFrame,
        trailingReserve: metaRidesReactionRow
          ? metrics.metaWidth + bubbleMetaInlineSpacing : 0.0))
    reactionStripView.frame = reactionFrame

    // Glyph box is 22pt (the touch target is grown separately below); it centres on the
    // bubble the way the "not sent" mark does, rather than hanging off its bottom corner
    // — bottom-aligning it against a one-line bubble put it visually below the row.
    let retrySize: CGFloat = 22.0
    if retryButton.isHidden {
      retryButton.frame = .zero
    } else {
      let retryX =
        row.isMe
        ? max(6.0, bubbleFrame.minX - retrySize - 6.0)
        : min(bounds.width - retrySize - 6.0, bubbleFrame.maxX + 6.0)
      let retryY = min(
        max(2.0, bubbleFrame.midY - retrySize / 2.0),
        max(2.0, bounds.height - retrySize - 2.0)
      )
      retryButton.frame = pixelAlignedRect(
        CGRect(x: retryX, y: retryY, width: retrySize, height: retrySize)
      )
    }

    if agentRegenerateButton.isHidden {
      agentRegenerateButton.frame = .zero
    } else {
      // Agent bubbles are always them-side: sit the button just past the
      // bubble's trailing edge, near its bottom (mirrors the error retry).
      let regenSize: CGFloat = 22.0
      let regenX = min(bounds.width - regenSize - 8.0, bubbleFrame.maxX + 7.0)
      let regenY = min(
        max(4.0, bubbleFrame.maxY - regenSize - 5.0),
        max(4.0, bounds.height - regenSize - 2.0)
      )
      agentRegenerateButton.frame = pixelAlignedRect(
        CGRect(x: regenX, y: regenY, width: regenSize, height: regenSize)
      )
    }

    if agentViewButton.isHidden {
      agentViewButton.frame = .zero
    } else {
      // Same trailing-edge / bottom placement as regenerate (mutually exclusive
      // with it: regenerate = errored turn, view-agent = completed turn).
      let viewSize: CGFloat = 22.0
      let viewX = min(bounds.width - viewSize - 8.0, bubbleFrame.maxX + 7.0)
      let viewY = min(
        max(4.0, bubbleFrame.maxY - viewSize - 5.0),
        max(4.0, bounds.height - viewSize - 2.0)
      )
      agentViewButton.frame = pixelAlignedRect(
        CGRect(x: viewX, y: viewY, width: viewSize, height: viewSize)
      )
    }

    if notSentIndicator.isHidden {
      notSentIndicator.frame = .zero
    } else {
      // Outgoing (me) bubbles are trailing-aligned: place the "!" just left of the
      // bubble's leading edge, vertically centered on it (iMessage "not delivered").
      //
      // The glyph reads at 16pt and the box is 30pt, because this is now the only way to
      // resend a failed message and a 16pt target is under half of Apple's 44pt minimum.
      // `contentMode = .center` means the extra space is pure touch area — the mark looks
      // identical, it is just no longer something you have to aim at.
      let notSentGlyph: CGFloat = 16.0
      let notSentSize: CGFloat = 30.0
      let notSentX = max(2.0, bubbleFrame.minX - notSentGlyph - 6.0 - (notSentSize - notSentGlyph) / 2.0)
      let notSentY = max(0.0, bubbleFrame.midY - notSentSize / 2.0)
      notSentIndicator.frame = pixelAlignedRect(
        CGRect(x: notSentX, y: notSentY, width: notSentSize, height: notSentSize)
      )
      if !notSentIndicatorShown {
        notSentIndicatorShown = true
        // Slide-in reveal: start nudged toward the bubble + faded, settle into place.
        notSentIndicator.alpha = 0.0
        notSentIndicator.transform = CGAffineTransform(translationX: notSentSize * 0.6, y: 0.0)
        UIView.animate(
          withDuration: 0.28, delay: 0.0, usingSpringWithDamping: 0.72,
          initialSpringVelocity: 0.4, options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
          self.notSentIndicator.alpha = 1.0
          self.notSentIndicator.transform = .identity
        }
      }
    }

    if !reactionStripView.isHidden {
      let signature =
        "\(row.messageId ?? "nil"):\(Int(reactionFrame.origin.x)):\(Int(reactionFrame.origin.y)):\(row.reactions.count)"
      if signature != lastReactionDebugSignature {
        lastReactionDebugSignature = signature
        reactionDebugLog(
          "layout success id=\(row.messageId ?? "nil") frame=\(reactionFrame) hidden=\(isGhostHidden ? "Y" : "N")"
        )
      }
    }

    CATransaction.commit()
    updateWallpaperBackdropLayoutIfNeeded()
  }

  /// Soft bottom fade on collapsed tall content so the cut reads as "more below",
  /// not a hard clip through glyphs. Expand/collapse only changes height in Y.
  private func applyTallCollapseFadeMask(to view: UIView, enabled: Bool) {
    guard enabled, view.bounds.width > 1.0, view.bounds.height > 1.0 else {
      clearTallCollapseFadeMask(on: view)
      return
    }
    let fade = min(tallBubbleCollapseFadeHeight, max(24.0, view.bounds.height * 0.22))
    let solidEnd = max(0.0, 1.0 - (fade / max(1.0, view.bounds.height)))
    let mask: CAGradientLayer
    if let existing = view.layer.mask as? CAGradientLayer {
      mask = existing
    } else {
      mask = CAGradientLayer()
      view.layer.mask = mask
    }
    mask.frame = view.bounds
    mask.startPoint = CGPoint(x: 0.5, y: 0.0)
    mask.endPoint = CGPoint(x: 0.5, y: 1.0)
    mask.colors = [
      UIColor.black.cgColor,
      UIColor.black.cgColor,
      UIColor.clear.cgColor,
    ]
    mask.locations = [0.0, NSNumber(value: Double(solidEnd)), 1.0]
  }

  private func clearTallCollapseFadeMask(on view: UIView) {
    if view.layer.mask is CAGradientLayer {
      view.layer.mask = nil
    }
  }

  /// Anchor for the list-hosted glass expand/collapse chip (nil when this row has none).
  /// Adds a restrained Y-scale to the visible body while the plate reveals/clips it.
  /// The translation compensates for UIView's center-based transform so the text's top
  /// edge stays fixed; only the lower edge breathes with the height transition.
  func animateTallBubbleInnerContent(expanding: Bool, duration: TimeInterval) {
    let bodyViews = (([messageLabel, richTextView] as [UIView]) + [_agentTurnContentView].compactMap { $0 as UIView? }).filter {
      !$0.isHidden && $0.bounds.width > 1.0 && $0.bounds.height > 1.0
    }
    guard !bodyViews.isEmpty else { return }

    tallContentAnimationGeneration &+= 1
    let generation = tallContentAnimationGeneration
    let compressedScaleY: CGFloat = 0.985

    func topAnchoredScale(for view: UIView, scaleY: CGFloat) -> CGAffineTransform {
      CGAffineTransform(
        a: 1.0,
        b: 0.0,
        c: 0.0,
        d: scaleY,
        tx: 0.0,
        ty: -view.bounds.height * (1.0 - scaleY) * 0.5
      )
    }

    for view in bodyViews {
      if let presentation = view.layer.presentation() {
        view.transform = presentation.affineTransform()
      }
      view.layer.removeAnimation(forKey: "transform")
      if expanding && view.transform.isIdentity {
        view.transform = topAnchoredScale(for: view, scaleY: compressedScaleY)
      }
    }

    UIView.animateKeyframes(
      withDuration: duration,
      delay: 0.0,
      options: [.allowUserInteraction, .beginFromCurrentState, .calculationModeCubic],
      animations: {
        if expanding {
          UIView.addKeyframe(withRelativeStartTime: 0.0, relativeDuration: 1.0) {
            bodyViews.forEach { $0.transform = .identity }
          }
        } else {
          UIView.addKeyframe(withRelativeStartTime: 0.0, relativeDuration: 0.68) {
            bodyViews.forEach {
              $0.transform = topAnchoredScale(for: $0, scaleY: compressedScaleY)
            }
          }
          UIView.addKeyframe(withRelativeStartTime: 0.68, relativeDuration: 0.32) {
            bodyViews.forEach { $0.transform = .identity }
          }
        }
      },
      completion: { [weak self] _ in
        guard let self, self.tallContentAnimationGeneration == generation else { return }
        bodyViews.forEach { $0.transform = .identity }
      }
    )
  }

  private func resetTallBubbleInnerContentAnimation() {
    tallContentAnimationGeneration &+= 1
    for view in (([messageLabel, richTextView] as [UIView]) + [_agentTurnContentView].compactMap { $0 as UIView? }) {
      view.layer.removeAnimation(forKey: "transform")
      view.transform = .identity
    }
  }

  func tallToggleAnchor() -> ChatTallToggleAnchor? {
    guard lastTallToggleVisible,
      let messageId = tallToggleRowMessageId, !messageId.isEmpty,
      lastBubbleFrame.width > 1.0, lastBubbleFrame.height > 1.0
    else { return nil }
    return ChatTallToggleAnchor(
      messageId: messageId,
      bubbleFrameInCell: lastBubbleFrame,
      collapsed: lastTallCollapsed,
      isMe: row?.isMe ?? false
    )
  }

  func updateWallpaperBackdropLayoutIfNeeded() {
    guard let coordinateView = wallpaperCoordinateView else {
      bubbleView.applyWallpaperBackdrop(snapshot: nil, containerSize: .zero, sampleRect: .zero)
      tailView.applyWallpaperBackdrop(snapshot: nil, containerSize: .zero, sampleRect: .zero)
      return
    }

    guard
      let row,
      row.kind == .message,
      !bubbleView.isHidden
    else {
      bubbleView.applyWallpaperBackdrop(snapshot: nil, containerSize: .zero, sampleRect: .zero)
      tailView.applyWallpaperBackdrop(snapshot: nil, containerSize: .zero, sampleRect: .zero)
      return
    }

    // Always pass bubble geometry in list coordinates so me gradients can map to one
    // shared chat-list space (even when there is no wallpaper snapshot).
    let bubbleRect = bubbleView.convert(bubbleView.bounds, to: coordinateView)
    let hasWallpaperSnapshot =
      wallpaperBackdropSnapshot != nil
      && wallpaperBackdropContainerSize.width > 1.0
      && wallpaperBackdropContainerSize.height > 1.0
    let containerSize =
      hasWallpaperSnapshot
      ? wallpaperBackdropContainerSize
      : coordinateView.bounds.size
    let prevWall = bubbleView.wallpaperSnapshot != nil
    bubbleView.applyWallpaperBackdrop(
      snapshot: hasWallpaperSnapshot ? wallpaperBackdropSnapshot : nil,
      containerSize: containerSize,
      sampleRect: bubbleRect
    )
    if chatCellBubbleFlickerDebugLogs, prevWall != hasWallpaperSnapshot {
      NSLog(
        "[BubbleFlicker] cell.wallpaperLayout id=%@ wall %@->%@ rect=(%.0f,%.0f,%.0fx%.0f) agent=%@",
        row.messageId ?? row.key,
        prevWall ? "Y" : "N",
        hasWallpaperSnapshot ? "Y" : "N",
        bubbleRect.minX,
        bubbleRect.minY,
        bubbleRect.width,
        bubbleRect.height,
        row.isAgentMessage ? "Y" : "N"
      )
    }

    if !tailView.isHidden, tailView.imageView.image == nil {
      let tailRect = tailView.convert(tailView.bounds, to: coordinateView)
      tailView.applyWallpaperBackdrop(
        snapshot: hasWallpaperSnapshot ? wallpaperBackdropSnapshot : nil,
        containerSize: containerSize,
        sampleRect: tailRect
      )
    } else {
      tailView.applyWallpaperBackdrop(snapshot: nil, containerSize: .zero, sampleRect: .zero)
    }

    // Agent style is border-only now and is already applied in configure(). Re-applying
    // on every wallpaper sample pass was thrashing fill colors every layout frame.
    // Only refresh agent chrome when wallpaper presence just flipped (configure already
    // painted the border for the steady-state path).
    if prevWall != hasWallpaperSnapshot {
      if row.isAgentMessage && !usesTransparentAgentStreamingLayout(row) {
        let accent = Self.agentWorkingAccent(for: row)
        bubbleView.applyAgentStyle(appearance: appearance, isMe: false, accent: accent)
        if !tailView.isHidden, tailView.imageView.image == nil {
          tailView.applyAgentTailStyle(appearance: appearance, isMe: false, accent: accent)
        }
      } else if row.isAgentMention {
        bubbleView.applyAgentStyle(appearance: appearance, isMe: true)
        if !tailView.isHidden, tailView.imageView.image == nil {
          tailView.applyAgentTailStyle(appearance: appearance, isMe: true)
        }
      }
    }
  }

  private func resolvedInlineVideoPlaybackURL(
    preferredLocalMediaURL: String?,
    row: ChatListRow
  ) -> URL? {
    if let localPath = resolvedLocalMediaPath(preferredLocalMediaURL),
      FileManager.default.fileExists(atPath: localPath)
    {
      inlineVideoLog("resolvedURL source=preferredLocal path=\(localPath)")
      return URL(fileURLWithPath: localPath)
    }
    if let localPath = resolvedLocalMediaPath(row.localMediaUrl),
      FileManager.default.fileExists(atPath: localPath)
    {
      inlineVideoLog("resolvedURL source=rowLocal path=\(localPath)")
      return URL(fileURLWithPath: localPath)
    }

    let requiresLocalPlayback =
      row.visualKind == .video
      || row.visualKind == .videoNote
      || (row.visualKind == .media && row.messageType != "file")
      || !(row.mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    guard !requiresLocalPlayback else {
      inlineVideoLog(
        "resolvedURL blockedLocalOnly mediaKey=\((row.mediaKey?.isEmpty == false) ? "Y" : "N") localRaw=\(row.localMediaUrl ?? "nil") remote=\(row.mediaUrl ?? "nil")"
      )
      return nil
    }

    let trimmedKey = row.mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard trimmedKey.isEmpty,
      let remoteRaw = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
      let remoteURL = URL(string: remoteRaw),
      let scheme = remoteURL.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else {
      inlineVideoLog(
        "resolvedURL failed preferredLocal=\(preferredLocalMediaURL ?? "nil") localRaw=\(row.localMediaUrl ?? "nil") remote=\(row.mediaUrl ?? "nil")"
      )
      return nil
    }
    inlineVideoLog("resolvedURL source=remote url=\(remoteURL.absoluteString)")
    return remoteURL
  }

  /// Session for user-started inline audio. Never on main and never for autoplay: the
  /// call crosses to the media daemon, and a main-thread round-trip has hung this app.
  private func configureInlineVideoAudioSession(muted: Bool) {
    ChatListCell.audioSessionQueue.async {
      let session = AVAudioSession.sharedInstance()
      do {
        if muted {
          try session.setCategory(.playback, mode: .default, options: .mixWithOthers)
        } else {
          try session.setCategory(.playback, mode: .default)
        }
        try session.setActive(true)
      } catch {
        // Best-effort; inline video is cosmetic.
      }
    }
  }

  /// Whether the playing item carries audio, resolved off main. The icon and the mute
  /// state follow once it answers; until then the video plays silently.
  private func loadInlineVideoAudioAvailability(from asset: AVAsset) {
    let identityKey = mediaVideoPlayerIdentityKey
    Task.detached(priority: .utility) { [weak self] in
      let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
      await MainActor.run {
        guard let self, self.mediaVideoPlayerIdentityKey == identityKey else { return }
        self.mediaVideoHasAudio = !audioTracks.isEmpty
        self.mediaVideoPlayer?.isMuted = self.mediaVideoIsMuted || !self.mediaVideoHasAudio
        self.updateInlineVideoAudioIcon()
      }
    }
  }

  private func stopInlineVideoPlayback(resetMutedState: Bool) {
    if mediaVideoPlayer != nil || mediaVideoPlayerURLKey != nil {
      inlineVideoLog(
        "stopPlayback resetMuted=\(resetMutedState ? "Y" : "N") ready=\(mediaVideoReady ? "Y" : "N") url=\(mediaVideoPlayerURLKey ?? "nil")"
      )
    }
    if let mediaVideoTimeObserver, let player = mediaVideoPlayer {
      player.removeTimeObserver(mediaVideoTimeObserver)
      self.mediaVideoTimeObserver = nil
    }
    mediaVideoStatusObserver?.invalidate()
    mediaVideoStatusObserver = nil
    if let mediaVideoLoopObserver {
      NotificationCenter.default.removeObserver(mediaVideoLoopObserver)
      self.mediaVideoLoopObserver = nil
    }
    mediaVideoPlayer?.pause()
    mediaVideoPlayer = nil
    _mediaVideoPlayerLayer?.player = nil
    _mediaVideoPlayerLayer?.opacity = 0.0
    mediaVideoPlayerHostView.isHidden = true
    mediaVideoPlayerURLKey = nil
    mediaVideoPlayerIdentityKey = nil
    mediaVideoReady = false
    mediaVideoCurrentTime = 0.0
    if resetMutedState {
      mediaVideoIsMuted = true
    }
    mediaVideoHasAudio = false
    updateInlineVideoTimeBadge()
    updateInlineVideoAudioIcon()
    updateMediaPlaceholderVisibility()
  }

  private func updateInlineVideoAudioIcon() {
    guard let row, row.visualKind == .video || row.visualKind == .videoNote else {
      mediaVideoAudioIconView.isHidden = true
      mediaVideoAudioIconView.image = nil
      mediaVideoAudioIconView.alpha = 1.0
      return
    }

    // Video notes: larger top-left mute control (Telegram diagram).
    let pointSize: CGFloat = 10.5
    let badgeSymbolConfig = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    let hasKnownAudio =
      mediaVideoHasAudio
      || resolvedVideoAudioState(
        preferredLocalMediaURL: effectivePreferredLocalMediaURL(nil),
        row: row
      ) == true
    let showsMutedIcon = mediaVideoIsMuted || !hasKnownAudio
    mediaVideoAudioIconView.isHidden = false
    mediaVideoAudioIconView.image = UIImage(
      systemName: showsMutedIcon ? "speaker.slash.fill" : "speaker.wave.2.fill",
      withConfiguration: badgeSymbolConfig
    )
    mediaVideoAudioIconView.alpha = hasKnownAudio ? 1.0 : 0.85
    if row.visualKind == .videoNote {
      mediaVideoAudioIconView.tintColor = .white
    }
  }

  private func updateInlineVideoTimeBadge() {
    guard let row, row.visualKind == .video || row.visualKind == .videoNote else {
      mediaDurationBadge.text = nil
      return
    }
    let resolvedDuration = mediaVideoTotalDuration ?? row.duration
    let nextText = formatBubblePlaybackTimer(
      current: mediaVideoCurrentTime,
      duration: resolvedDuration
    )
    guard mediaDurationBadge.text != nextText else { return }
    mediaDurationBadge.text = nextText
    setNeedsLayout()
  }

  private func attachInlineVideoTimeObserver(to player: AVPlayer) {
    if let mediaVideoTimeObserver {
      player.removeTimeObserver(mediaVideoTimeObserver)
      self.mediaVideoTimeObserver = nil
    }
    mediaVideoTimeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
      queue: .main
    ) { [weak self] time in
      guard let self else { return }
      self.mediaVideoCurrentTime = max(0.0, CMTimeGetSeconds(time))
      self.updateInlineVideoTimeBadge()
    }
  }

  /// Show or hide the transfer scrim without forcing it to exist.
  ///
  /// This is the whole reason the lazy views need a helper rather than a `lazy var`.
  /// Almost every call here is `hidden: true` — every text bubble, every settled photo,
  /// every early return below — and a plain `mediaPlaceholderBlurView.isHidden = true`
  /// would construct a `UIVisualEffectView` in order to hide it, which is the cost this
  /// was meant to remove. Hiding something that was never built is a no-op.
  private func setMediaPlaceholderHidden(_ hidden: Bool) {
    if hidden {
      _mediaPlaceholderBlurView?.isHidden = true
    } else {
      mediaPlaceholderBlurView.isHidden = false
    }
  }

  /// Re-tint the scrim only if it exists. A fully transparent tint on a scrim that was
  /// never built is the same picture.
  private func setMediaPlaceholderTint(white: CGFloat, alpha: CGFloat) {
    guard alpha > 0 || _mediaPlaceholderTintView != nil else { return }
    mediaPlaceholderTintView.backgroundColor = UIColor(white: white, alpha: alpha)
  }

  /// The best thumb this row can produce without the network: the decoded thumb caches
  /// first, then the durable base64 the message carries.
  private func lastResortMicroThumb(for row: ChatListRow) -> UIImage? {
    let key = "thumb-\(row.key)"
    if let decoded = chatMicroThumbDecodedCache.object(forKey: key as NSString) {
      return decoded
    }
    if let warm = chatMediaImageCache.object(forKey: key as NSString) {
      return warm
    }
    let source = row.thumbnailBase64 ?? row.attachmentThumbnailsB64.first
    return chatDecodedMicroThumbnail(fromBase64: source, cacheKey: key)
  }

  /// Drops the hero image only when nothing of value is in it. Artwork paths used to
  /// blank a good picture on their way to the play plate.
  private func clearMediaImageIfNoBetterPixels() {
    guard mediaPixelQuality == .none else { return }
    mediaImageView.image = nil
  }

  private func updateMediaPlaceholderVisibility() {
    guard let row else {
      setMediaPlaceholderHidden(true)
      return
    }
    let supportsPlaceholder =
      row.visualKind == .video
      || row.visualKind == .videoNote
      || row.visualKind == .document
      || (row.visualKind == .media && row.messageType != "file")
    guard supportsPlaceholder else {
      setMediaPlaceholderHidden(true)
      return
    }
    let hasInlineVideo =
      !mediaVideoPlayerHostView.isHidden && mediaVideoReady
      && _mediaVideoPlayerLayer?.player != nil
    if hasInlineVideo {
      // Live video frames replace any still preview.
      setMediaPlaceholderHidden(true)
      return
    }
    // A sticker surface that was never built is, by definition, not showing a sticker.
    if _mediaStickerAnimationView?.isHidden == false {
      setMediaPlaceholderHidden(true)
      return
    }
    var hasPixels = mediaImageView.image != nil
    // Last chance before the dark plate: a thumb this row already decoded, or the one on
    // the wire. The scrim is only honest when nothing at all exists.
    if !hasPixels, !mediaImageView.isHidden, row.visualKind != .document,
      !shouldShowViewOnceShineCover(row),
      let recovered = lastResortMicroThumb(for: row)
    {
      mediaImageView.image = recovered
      mediaPixelQuality = .microThumb
      hasPixels = true
    }
    if row.visualKind == .document {
      let resolvedPage = mediaPixelQuality == .full
      setMediaPlaceholderHidden(resolvedPage)
      setMediaPlaceholderTint(
        white: appearance.isDark ? 0.0 : 1.0,
        alpha: resolvedPage ? 0.0 : (appearance.isDark ? 0.28 : 0.14)
      )
      return
    }
    let transferPending =
      mediaIsDownloading || mediaNeedsDownload || row.shouldShowUploadOverlay
    if hasPixels {
      // Telegram-style: soft material over the micro-thumb while full media is still
      // transferring. Full-quality pixels hide the overlay.
      let softContentBlur =
        transferPending && mediaPixelQuality == .microThumb
      setMediaPlaceholderHidden(!softContentBlur)
      setMediaPlaceholderTint(
        white: appearance.isDark ? 0.0 : 1.0,
        alpha: softContentBlur ? (appearance.isDark ? 0.28 : 0.14) : 0.0
      )
    } else {
      // Last resort only — no durable thumb on the wire. Prefer never reaching here.
      setMediaPlaceholderHidden(false)
      setMediaPlaceholderTint(
        white: appearance.isDark ? 0.02 : 0.98,
        alpha: appearance.isDark ? 0.18 : 0.10
      )
    }
  }

  private func refreshInlineVideoPlaybackIfNeeded(
    preferredLocalMediaURL: String? = nil
  ) {
    let effectivePreferredLocalMediaURL = effectivePreferredLocalMediaURL(preferredLocalMediaURL)
    guard let row else {
      inlineVideoLog("refresh skip=noRow")
      stopInlineVideoPlayback(resetMutedState: true)
      return
    }
    guard row.visualKind == .video || row.visualKind == .videoNote else {
      inlineVideoLog("refresh skip=nonVideo visualKind=\(row.visualKind)")
      stopInlineVideoPlayback(resetMutedState: true)
      return
    }
    if shouldShowViewOnceShineCover(row) {
      mediaVideoPlayer?.pause()
      _mediaVideoPlayerLayer?.opacity = 0.0
      mediaVideoPlayerHostView.isHidden = true
      return
    }
    guard mediaVideoPlaybackActive, window != nil, !isContextMenuExtracted,
      !row.shouldShowUploadOverlay, !mediaIsDownloading
    else {
      inlineVideoLog(
        "refresh pause active=\(mediaVideoPlaybackActive ? "Y" : "N") hasWindow=\(window != nil ? "Y" : "N") extracted=\(isContextMenuExtracted ? "Y" : "N") uploading=\(row.shouldShowUploadOverlay ? "Y" : "N") downloading=\(mediaIsDownloading ? "Y" : "N")"
      )
      mediaVideoPlayer?.pause()
      _mediaVideoPlayerLayer?.opacity = 0.0
      mediaVideoPlayerHostView.isHidden = true
      updateInlineVideoAudioIcon()
      updateMediaPlaceholderVisibility()
      return
    }
    guard let playbackURL = resolvedInlineVideoPlaybackURL(
      preferredLocalMediaURL: effectivePreferredLocalMediaURL, row: row)
    else {
      inlineVideoLog(
        "refresh noPlaybackURL preferredLocal=\(effectivePreferredLocalMediaURL ?? "nil") localRaw=\(row.localMediaUrl ?? "nil") remote=\(row.mediaUrl ?? "nil")"
      )
      stopInlineVideoPlayback(resetMutedState: false)
      return
    }

    let playbackKey = playbackURL.absoluteString
    // Keyed on the media's identity, not the resolved path: patching `localMediaUrl` to the
    // same bytes used to tear the player down and hide the host until readyToPlay again.
    let identityKey = chatMediaRemoteIdentity(row) ?? playbackKey
    let playerFileStillThere =
      mediaVideoPlayerURLKey.map {
        !$0.hasPrefix("file:") || FileManager.default.fileExists(atPath: URL(string: $0)?.path ?? "")
      } ?? false
    let reusesPlayer =
      mediaVideoPlayer != nil && mediaVideoPlayerIdentityKey == identityKey && playerFileStillThere
    inlineVideoLog(
      "refresh start url=\(playbackKey) ready=\(mediaVideoReady ? "Y" : "N") reuse=\(reusesPlayer ? "Y" : "N")"
    )
    if !reusesPlayer {
      stopInlineVideoPlayback(resetMutedState: false)
      let playerItem = AVPlayerItem(url: playbackURL)
      let player = AVPlayer(playerItem: playerItem)
      player.actionAtItemEnd = .none
      player.isMuted = true
      mediaVideoCurrentTime = 0.0
      mediaVideoPlayer = player
      mediaVideoPlayerLayer.player = player
      mediaVideoPlayerURLKey = playbackKey
      mediaVideoPlayerIdentityKey = identityKey
      mediaVideoPlayerHostView.isHidden = false
      mediaVideoReady = false
      mediaVideoHasAudio = false
      attachInlineVideoTimeObserver(to: player)
      updateInlineVideoTimeBadge()
      inlineVideoLog("player create url=\(playbackKey)")
      mediaVideoLoopObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime,
        object: playerItem,
        queue: .main
      ) { [weak self] _ in
        guard let self, let player = self.mediaVideoPlayer else { return }
        if self.row?.visualKind == .videoNote, self.agentTurnState.videoNoteExpanded {
          let elapsed = ProcessInfo.processInfo.systemUptime - self.videoNoteExpandSessionAt
          if elapsed < 0.5 {
            player.seek(to: .zero)
            player.play()
            return
          }
          player.pause()
          player.seek(to: .zero)
          self.mediaVideoCurrentTime = 0.0
          self.mediaVideoHasCompletedOnce = true
          self.mediaVideoUserPaused = true
          self.updateInlineVideoTimeBadge()
          self.refreshInlineVideoPlayGlyph()
          self.onVideoNotePlaybackEnded?()
          return
        }
        self.inlineVideoLog("player ended once url=\(playbackKey)")
        player.pause()
        player.seek(to: .zero)
        self.mediaVideoCurrentTime = 0.0
        self.mediaVideoHasCompletedOnce = true
        self.mediaVideoUserPaused = true
        self.updateInlineVideoTimeBadge()
        self.refreshInlineVideoPlayGlyph()
      }
      mediaVideoStatusObserver = playerItem.observe(\.status, options: [.initial, .new]) {
        [weak self] item, _ in
        guard let self else { return }
        DispatchQueue.main.async {
          switch item.status {
          case .readyToPlay:
            self.mediaVideoReady = true
            let duration = CMTimeGetSeconds(item.duration)
            if duration.isFinite, duration > 0.0 {
              self.mediaVideoTotalDuration = duration
            }
            // Track loading is async: a sync `tracks(withMediaType:)` blocks main until the
            // asset's format is parsed. Playback starts muted and the icon updates after.
            self.loadInlineVideoAudioAvailability(from: item.asset)
            self.mediaVideoPlayer?.isMuted = self.mediaVideoIsMuted || !self.mediaVideoHasAudio
            self._mediaVideoPlayerLayer?.opacity = 1.0
            self.mediaVideoPlayerHostView.isHidden = false
            if self.mediaVideoHasCompletedOnce || self.mediaVideoUserPaused {
              self.mediaVideoPlayer?.pause()
            } else {
              // Autoplay never touches the audio session — only an explicit play/unmute does.
              if self.mediaVideoUserInitiatedPlay {
                self.configureInlineVideoAudioSession(
                  muted: self.mediaVideoIsMuted || !self.mediaVideoHasAudio)
              }
              self.mediaVideoPlayer?.play()
            }
            self.updateInlineVideoTimeBadge()
            self.refreshInlineVideoPlayGlyph()
            self.inlineVideoLog(
              "player ready url=\(playbackKey) hasAudio=\(self.mediaVideoHasAudio ? "Y" : "N") muted=\(self.mediaVideoPlayer?.isMuted == true ? "Y" : "N") duration=\(CMTimeGetSeconds(item.duration))"
            )
          case .failed:
            self.mediaVideoReady = false
            self._mediaVideoPlayerLayer?.opacity = 0.0
            self.mediaVideoPlayerHostView.isHidden = true
            self.inlineVideoLog(
              "player failed url=\(playbackKey) error=\(item.error?.localizedDescription ?? "nil")"
            )
          case .unknown:
            fallthrough
          @unknown default:
            self.mediaVideoReady = false
            self._mediaVideoPlayerLayer?.opacity = 0.0
            self.inlineVideoLog("player unknown url=\(playbackKey)")
          }
          self.updateInlineVideoAudioIcon()
          self.updateMediaPlaceholderVisibility()
        }
      }
    }

    mediaVideoPlayer?.isMuted = mediaVideoIsMuted || !mediaVideoHasAudio
    if mediaVideoReady {
      mediaVideoPlayerHostView.isHidden = false
      _mediaVideoPlayerLayer?.opacity = 1.0
      if mediaVideoHasCompletedOnce || mediaVideoUserPaused {
        mediaVideoPlayer?.pause()
      } else {
        // Silent autoplay needs no session change; only a user play/unmute does.
        if mediaVideoUserInitiatedPlay {
          configureInlineVideoAudioSession(muted: mediaVideoIsMuted || !mediaVideoHasAudio)
        }
        mediaVideoPlayer?.play()
      }
      inlineVideoLog(
        "player play url=\(playbackKey) timeControl=\(mediaVideoPlayer?.timeControlStatus.rawValue ?? -1)"
      )
    }
    refreshInlineVideoPlayGlyph()
    updateInlineVideoAudioIcon()
    updateMediaPlaceholderVisibility()
  }

  private func effectivePreferredLocalMediaURL(_ candidate: String?) -> String? {
    let trimmedCandidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmedCandidate.isEmpty {
      return trimmedCandidate
    }
    let trimmedOverride = preferredLocalMediaURLOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmedOverride.isEmpty ? nil : trimmedOverride
  }

  private func inlineVideoLog(_ message: String) {
    guard chatCellInlineVideoDebugLogs else { return }
    let rowId = row?.messageId ?? "-"
    let visualKind = row.map { "\($0.visualKind)" } ?? "nil"
    NSLog("[ChatInlineVideo] msgId=%@ vk=%@ %@", rowId, visualKind, message)
  }

  private func resolvedVideoAudioState(
    preferredLocalMediaURL: String?,
    row: ChatListRow
  ) -> Bool? {
    let candidates = [preferredLocalMediaURL, row.localMediaUrl, row.mediaUrl]
    for candidate in candidates {
      if let cached = cachedVideoHasAudio(for: candidate) {
        return cached
      }
      if let hasAudio = probeLocalVideoHasAudio(for: candidate) {
        cacheVideoHasAudio(hasAudio, for: candidate)
        return hasAudio
      }
    }
    return nil
  }

  private func configureVideoInfoBadge(
    for row: ChatListRow,
    preferredLocalMediaURL: String?
  ) {
    let isVideo = row.visualKind == .video || row.visualKind == .videoNote
    guard isVideo else {
      mediaVideoInfoBadgeView.isHidden = true
      mediaDurationBadge.isHidden = true
      mediaDurationBadge.text = nil
      mediaVideoAudioIconView.isHidden = true
      mediaVideoAudioIconView.image = nil
      return
    }

    mediaVideoInfoBadgeView.isHidden = false
    mediaDurationBadge.isHidden = false
    mediaVideoTotalDuration = row.duration
    if mediaVideoPlayer == nil {
      mediaVideoCurrentTime = 0.0
    }
    updateInlineVideoTimeBadge()

    if let hasAudio = resolvedVideoAudioState(preferredLocalMediaURL: preferredLocalMediaURL, row: row) {
      mediaVideoHasAudio = hasAudio
    }
    updateInlineVideoAudioIcon()
  }

  /// Multi-image bridge message → populate the tile grid from the sealed blobs and
  /// hide the single hero image (the grid owns the whole media canvas). Runs after the
  /// visualKind switch so hiding mediaImageView also skips the hero-image load path.
  private func configureMediaGrid(for row: ChatListRow) {
    let count = chatMediaGridImageCount(row)
    guard count > 1 else {
      mediaGridRowKey = nil
      mediaStackView?.isHidden = true
      mediaStackView?.configure(count: 0, mode: .deck, aspect: 1.0, resetIndex: true)
      return
    }

    let tiles = min(count, chatMediaGridMaxTiles)
    let stack = ensureMediaStackView()
    stack.isHidden = false

    mediaImageView.isHidden = true
    mediaPrimaryIconView.isHidden = true
    // The stack needs hit-testing; keep the container interactive while it is live.
    mediaContainerView.isUserInteractionEnabled = true
    let rowKey = row.messageId ?? row.key
    // A recycled cell must not open on the picture the *previous* message was
    // left on, so the index resets whenever the row identity changes.
    let isNewRow = mediaGridRowKey != rowKey
    mediaGridRowKey = rowKey
    stack.configure(
      count: tiles,
      mode: chatMediaStackMode(row),
      aspect: ChatMediaStackGeometry.cardAspect(natural: resolvedMediaNaturalSize(for: row)),
      resetIndex: isNewRow
    )

    for index in 0..<tiles {
      let cacheKey = "\(rowKey)#grid-\(index)" as NSString
      if let cached = ChatListCell.bridgeGridImageCache.object(forKey: cacheKey) {
        stack.setImage(cached, at: index)
        continue
      }
      // Prefer live sealed blobs; fall back to durable server-persisted thumbs after reopen.
      let blob = index < row.agentBridgeAttachmentsEnc.count
        ? row.agentBridgeAttachmentsEnc[index] : nil
      let thumbB64 = index < row.attachmentThumbnailsB64.count
        ? row.attachmentThumbnailsB64[index] : nil
      // Plain-chat multi-image: each picture has its own uploaded URL and its own
      // media key. The thumb only shapes the card; this is what fills it.
      let remoteURL = index < row.attachmentUrls.count ? row.attachmentUrls[index] : nil
      let remoteKey = index < row.attachmentMediaKeys.count
        ? row.attachmentMediaKeys[index] : nil
      ChatListCell.bridgeGridDecodeQueue.async { [weak self] in
        var image: UIImage?
        if let blob {
          image = ChatListCell.decodeBridgeGridImage(blob: blob)
        }
        if image == nil, let remoteURL, !remoteURL.isEmpty {
          image = ChatListCell.loadMultiImageCard(
            remoteURL: remoteURL, mediaKey: (remoteKey?.isEmpty == false) ? remoteKey : nil)
        }
        if image == nil, let thumbB64,
          let data = Data(base64Encoded: thumbB64, options: [.ignoreUnknownCharacters])
        {
          image = UIImage(data: data)
        }
        guard let image else { return }
        ChatListCell.bridgeGridImageCache.setObject(image, forKey: cacheKey)
        DispatchQueue.main.async {
          guard let self, self.mediaGridRowKey == rowKey else { return }
          self.mediaStackView?.setImage(image, at: index)
        }
      }
    }
  }

  /// Built on first use: most cells never carry more than one image, and a stack
  /// view per cell would be paid for on every row in the chat.
  private func ensureMediaStackView() -> ChatMediaStackView {
    if let mediaStackView { return mediaStackView }
    let stack = ChatMediaStackView()
    stack.onTap = { [weak self] index, view in
      guard let self, let row = self.row else { return }
      // Don't open while upload/download overlay is active — cancel path owns the center.
      if row.shouldShowUploadOverlay || self.mediaIsDownloading { return }
      self.onMediaGridTileTap?(row, index, view)
    }
    mediaContainerView.insertSubview(stack, aboveSubview: mediaImageView)
    mediaStackView = stack
    return stack
  }

  /// Public entry for gallery/filmstrip seeding from sealed bridge blobs.
  static func decodeBridgeGridImagePublic(blob: String) -> UIImage? {
    decodeBridgeGridImage(blob: blob)
  }

  /// One picture of a multi-image message, by its own URL and its own key.
  /// Synchronous by design: it is already called on `bridgeGridDecodeQueue`,
  /// alongside the blob decode it stands in for.
  static func loadMultiImageCard(remoteURL: String, mediaKey: String?) -> UIImage? {
    let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("/"), let image = UIImage(contentsOfFile: trimmed) { return image }
    if let fileURL = URL(string: trimmed), fileURL.isFileURL,
      let image = UIImage(contentsOfFile: fileURL.path)
    {
      return image
    }
    // Same cache slot the hero image uses, keyed on URL *and* key — a signed URL
    // alone is not a stable identity for the bytes behind it.
    let cacheKey = chatMediaCacheKey(trimmed, mediaKey: mediaKey)
    if let cached = chatMediaDiskCacheLoad(cacheKey),
      let image = UIImage(data: cached)
    {
      return image
    }
    guard let url = URL(string: trimmed), let data = try? Data(contentsOf: url) else {
      return nil
    }
    // Try decrypted first, then the raw bytes: a stale or absent key must not
    // leave a permanently blank card.
    if let decrypted = chatMediaDecryptedDataIfNeeded(data, mediaKey: mediaKey),
      let image = UIImage(data: decrypted)
    {
      chatMediaDiskCacheSave(decrypted, forKey: cacheKey)
      return image
    }
    guard let image = UIImage(data: data) else { return nil }
    chatMediaDiskCacheSave(data, forKey: cacheKey)
    return image
  }

  /// Open one sealed arte1 image blob into a tile-sized UIImage. Returns nil when the
  /// pairing key is missing on this device (tile keeps its placeholder fill).
  private static func decodeBridgeGridImage(blob: String) -> UIImage? {
    guard let object = AgentRuntimeCrypto.decrypt(blob) else { return nil }
    func str(_ any: Any?) -> String? {
      guard let s = any as? String else { return nil }
      let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let b64 = str(object["dataB64"]) ?? str(object["data_b64"]) ?? str(object["base64"]),
      let data = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]),
      let image = UIImage(data: data)
    {
      return downscaledGridImage(image)
    }
    if let uri = str(object["uri"]) ?? str(object["url"]) ?? str(object["path"]) {
      let path: String
      if let parsed = URL(string: uri), parsed.isFileURL {
        path = parsed.path
      } else {
        path = uri
      }
      if FileManager.default.fileExists(atPath: path),
        let image = UIImage(contentsOfFile: path)
      {
        return downscaledGridImage(image)
      }
    }
    return nil
  }

  private static func downscaledGridImage(_ image: UIImage) -> UIImage {
    let maxDimension: CGFloat = 700.0
    let size = image.size
    let longest = max(size.width, size.height, 1.0)
    guard longest > maxDimension else { return image }
    let scale = maxDimension / longest
    let target = CGSize(width: size.width * scale, height: size.height * scale)
    let renderer = UIGraphicsImageRenderer(size: target)
    return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
  }

  private func setMediaTransferOverlayVisible(_ visible: Bool) {
    if visible {
      if mediaTransferChromeShown {
        mediaProgressOverlayView.isHidden = false
        mediaProgressOverlayView.isUserInteractionEnabled = true
        mediaProgressOverlayView.alpha = 1
        return
      }
      mediaTransferChromeShown = true
      mediaProgressOverlayView.isHidden = false
      mediaProgressOverlayView.isUserInteractionEnabled = true
      mediaProgressOverlayView.alpha = 0
      mediaProgressOverlayView.transform = .identity
      UIView.animate(
        withDuration: 0.28, delay: 0,
        options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
      ) {
        self.mediaProgressOverlayView.alpha = 1
      }
    } else if mediaTransferChromeShown {
      mediaTransferChromeShown = false
      mediaProgressOverlayView.isUserInteractionEnabled = false
      UIView.animate(
        withDuration: 0.20, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]
      ) {
        self.mediaProgressOverlayView.alpha = 0
      } completion: { _ in
        if !self.mediaTransferChromeShown {
          self.mediaProgressOverlayView.isHidden = true
          self.mediaProgressOverlayView.alpha = 1
        }
      }
    } else {
      mediaProgressOverlayView.isHidden = true
      mediaProgressOverlayView.isUserInteractionEnabled = false
      mediaProgressOverlayView.alpha = 1
      mediaProgressOverlayView.transform = .identity
    }
  }

  private func updateMediaTransferChrome(for row: ChatListRow) {
    let hidesLocalGifTransfer = row.isMe && row.messageType == "gif"
    if hidesLocalGifTransfer {
      mediaTransferChromeShown = false
      mediaProgressOverlayView.isHidden = true
      mediaProgressRingView.isHidden = true
      mediaProgressRingView.setUploadState(isUploading: false, progress: nil)
      mediaProgressRingView.setDownloadState(
        needsDownload: false, isDownloading: false, progress: nil)
      mediaProgressSpinner.stopAnimating()
      mediaProgressSizeLabel.isHidden = true
      mediaProgressSizeLabel.text = nil
      mediaPrimaryIconView.isHidden = true
      return
    }

    let hasActiveTransfer = row.shouldShowUploadOverlay || mediaIsDownloading
    mediaProgressOverlayView.backgroundColor = .clear
    mediaProgressRingView.isHidden = !hasActiveTransfer
    mediaProgressSpinner.stopAnimating()
    mediaProgressSpinner.isHidden = true
    setMediaTransferOverlayVisible(hasActiveTransfer)

    if row.shouldShowUploadOverlay {
      // Only real byte progress counts — until the first upload callback the ring is an
      // indeterminate spinner and the badge shows just the total size, never a fake
      // "already sent" fraction.
      let realProgress: Double? = {
        guard let value = row.uploadProgress, value.isFinite, value > 0.004 else { return nil }
        return max(0.0, min(1.0, value))
      }()
      mediaProgressRingView.setDownloadState(needsDownload: false, isDownloading: false, progress: nil)
      mediaProgressRingView.setUploadState(isUploading: true, progress: realProgress)
      if let totalBytes = row.fileSize, totalBytes > 0 {
        let totalStr = formatMediaByteSize(totalBytes)
        if let progress = realProgress {
          let sentBytes = Int64(Double(totalBytes) * progress)
          mediaProgressSizeLabel.text = "  \(formatMediaByteSize(sentBytes)) / \(totalStr)  "
        } else {
          mediaProgressSizeLabel.text = "  \(totalStr)  "
        }
        mediaProgressSizeLabel.isHidden = false
      } else {
        mediaProgressSizeLabel.text = "  Uploading  "
        mediaProgressSizeLabel.isHidden = false
      }
    } else if mediaIsDownloading {
      let realProgress: Double? = {
        guard let value = mediaDownloadProgress, value.isFinite, value > 0.004 else { return nil }
        return max(0.0, min(1.0, value))
      }()
      mediaProgressRingView.setUploadState(isUploading: false, progress: nil)
      mediaProgressRingView.setDownloadState(
        needsDownload: true,
        isDownloading: true,
        progress: realProgress
      )
      if let totalBytes = row.fileSize, totalBytes > 0 {
        let totalStr = formatMediaByteSize(totalBytes)
        if let progress = realProgress {
          let receivedBytes = Int64(Double(totalBytes) * progress)
          mediaProgressSizeLabel.text = "  \(formatMediaByteSize(receivedBytes)) / \(totalStr)  "
        } else {
          mediaProgressSizeLabel.text = "  \(totalStr)  "
        }
        mediaProgressSizeLabel.isHidden = false
      } else {
        mediaProgressSizeLabel.text = "  Downloading  "
        mediaProgressSizeLabel.isHidden = false
      }
    } else {
      mediaProgressRingView.setUploadState(isUploading: false, progress: nil)
      mediaProgressRingView.setDownloadState(needsDownload: false, isDownloading: false, progress: nil)
      mediaProgressSizeLabel.text = nil
      mediaProgressSizeLabel.isHidden = true
    }

    if row.visualKind == .videoNote {
      // Circular note: a centred spinner only, never a byte counter.
      mediaProgressSizeLabel.isHidden = true
      mediaProgressSizeLabel.text = nil
    }

    let shouldShowPrimaryIcon: Bool = {
      switch row.visualKind {
      case .video, .videoNote:
        return true
      case .media:
        return row.messageType == "file"
      case .document:
        return mediaImageView.image == nil
      case .text, .voice, .sticker:
        return false
      }
    }()
    if row.visualKind == .video || row.visualKind == .videoNote {
      refreshInlineVideoPlayGlyph()
    } else {
      mediaPrimaryIconView.isHidden =
        row.shouldShowUploadOverlay || mediaIsDownloading || !shouldShowPrimaryIcon
    }

    if row.visualKind == .video || row.visualKind == .videoNote {
      mediaVideoInfoBadgeView.isHidden =
        hasActiveTransfer || (row.viewOnce && row.visualKind == .video)
    } else {
      mediaVideoInfoBadgeView.isHidden = true
    }
    // Soft content blur rides transfer state — refresh whenever chrome flips.
    updateMediaPlaceholderVisibility()
  }

  private func resolvedVoicePlaybackURL(for row: ChatListRow) -> String? {
    let local = row.localMediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
    // Local wins only while the file is actually there; a dead path would otherwise mask
    // the vault copy behind a bubble that claims it needs no download and plays nothing.
    if let local, !local.isEmpty, let existing = chatExistingLocalMediaPath(local) {
      return existing
    }
    let remote = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let remote, !remote.isEmpty {
      return remote
    }
    return nil
  }

  /// Voice chrome (waveform bars + play plate) is colored by WHO sent the row, not by
  /// the accent alone:
  ///
  ///   * My bubbles — the plate and bars take the bubble's own text color, and the
  ///     glyph is punched out of the plate so it reads as the bubble color. Appearance
  ///     never tints them; against my accent-filled bubble a second accent went muddy.
  ///   * Their bubbles — the plate and bars take the appearance accent (their plate is
  ///     near-black, so the accent is what carries), while the glyph stays white no
  ///     matter which appearance is selected.
  private func applyVoiceChromeColors(isMe: Bool) {
    let tint = isMe ? appearance.textColorMe : appearance.accent
    mediaWaveformView.applyColors(
      active: tint.withAlphaComponent(0.98),
      inactive: tint.withAlphaComponent(0.34)
    )
    mediaVoiceButtonView.applyStyle(
      fillColor: tint,
      // Knocked out on my side, so this tint only applies to the artwork variant,
      // where `resolvedIconTintColor` forces white anyway.
      iconTint: isMe ? .clear : .white,
      ringTint: tint.withAlphaComponent(0.82),
      knockoutIcon: isMe
    )
  }

  /// Compact music cell labels: title = track name, detail = artist (or source).
  private func applyCompactMusicTextLabels(for row: ChatListRow) {
    let stack = musicCardTextStack(for: row)
    let textColor = row.isMe ? appearance.textColorMe : appearance.textColorThem
    mediaTitleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
    mediaTitleLabel.textColor = textColor
    mediaTitleLabel.text = stack.title
    mediaTitleLabel.numberOfLines = 1

    mediaDetailLabel.attributedText = nil
    mediaDetailLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
    mediaDetailLabel.textColor = textColor.withAlphaComponent(0.72)
    mediaDetailLabel.numberOfLines = 1
    if let artist = stack.artist, !artist.isEmpty {
      mediaDetailLabel.text = artist
    } else {
      mediaDetailLabel.text = stack.source
    }
  }

  private func refreshVoiceMetadataText() {
    guard let row, row.visualKind == .voice else { return }
    let usesMetadata = usesAudioMetadataVoiceLayout(row)

    if row.shouldShowUploadOverlay {
      // Sending a voice note: show its DURATION (the timer) alongside the spinner on the
      // play plate — never the byte size. A short voice note is not heavy media, and a
      // size/progress readout is exactly the noise the user asked to remove. Music keeps
      // its title/artist (same as the download branch); the spinner carries the state.
      if usesMetadata {
        applyCompactMusicTextLabels(for: row)
      } else {
        mediaDetailLabel.attributedText = nil
        mediaDetailLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        mediaDetailLabel.numberOfLines = 1
        mediaDetailLabel.text = "\(formatBubbleDuration(seconds: row.duration)) \u{2022}"
      }
      return
    }

    if mediaDownloadFailed {
      if usesMetadata {
        mediaTitleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        mediaTitleLabel.text = resolvedAudioVoiceTitle(row)
        mediaTitleLabel.textColor = row.isMe ? appearance.textColorMe : appearance.textColorThem
      }
      mediaDetailLabel.attributedText = nil
      mediaDetailLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
      mediaDetailLabel.numberOfLines = 1
      mediaDetailLabel.text = VoiceBubblePlaybackCoordinator.shared.voiceFailureCaption(
        for: row.messageId
      )
      return
    }

    if mediaIsDownloading {
      // Both music and plain voice keep their normal caption during download — music its
      // title/artist, a voice note its DURATION timer. The spinner badge carries the loading
      // state, so the cell never shows a byte-size caption (that read as noise and churned
      // 5%→0 on the old broken loop). Voice is not heavy media; timer + spinner is all.
      if usesMetadata {
        applyCompactMusicTextLabels(for: row)
      } else {
        mediaDetailLabel.attributedText = nil
        mediaDetailLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        mediaDetailLabel.numberOfLines = 1
        mediaDetailLabel.text = "\(formatBubbleDuration(seconds: row.duration)) \u{2022}"
      }
      return
    }

    if usesMetadata {
      applyCompactMusicTextLabels(for: row)
    } else {
      mediaDetailLabel.attributedText = nil
      mediaDetailLabel.text = "\(formatBubbleDuration(seconds: row.duration)) \u{2022}"
    }
  }

  private func configureMediaPresentation(
    for row: ChatListRow,
    textColor: UIColor,
    metaColor: UIColor,
    preservedMediaImage: UIImage?,
    isSameMessage: Bool,
    mediaKindChanged: Bool
  ) {
    let isTransparentSticker = isTransparentStickerMessage(row)
    if row.visualKind != .sticker {
      resetStickerAnimation()
    }
    mediaPrimaryIconView.isHidden = true
    mediaVoiceButtonView.isHidden = true
    mediaTitleLabel.isHidden = true
    mediaDetailLabel.isHidden = true
    mediaWaveformView.isHidden = true
    mediaVideoInfoBadgeView.isHidden = true
    mediaVideoAudioIconView.isHidden = true
    mediaVideoAudioIconView.image = nil
    mediaDurationBadge.isHidden = true
    mediaImageView.isHidden = true
    _mediaStickerAnimationView?.isHidden = true
    // Pixels are only ever cleared for a different message or a different kind. The
    // ladder below promotes; a reconfigure of the same bubble must never blank it.
    if let preservedMediaImage {
      if mediaImageView.image !== preservedMediaImage {
        mediaImageView.image = preservedMediaImage
      }
    } else if !isSameMessage || mediaKindChanged {
      mediaImageView.image = nil
    }
    // Only new media cancels an in-flight fetch/decode. A status or selection reconfigure
    // of the same bubble used to restart the download on every pass.
    if !isSameMessage || mediaKindChanged {
      mediaImageTask?.cancel()
      mediaImageTask = nil
      mediaImageTaskKey = nil
      mediaDecodeInFlightKey = nil
    }
    musicCoverTask?.cancel()
    musicCoverTask = nil
    mediaPrimaryIconView.image = nil
    mediaTitleLabel.text = nil
    mediaDetailLabel.text = nil
    mediaDurationBadge.text = nil
    if mediaKindChanged {
      mediaWaveformView.setWaveform(nil)
      mediaVoiceButtonView.setArtworkImage(nil)
    }
    if row.visualKind != .voice {
      mediaVoiceButtonView.setUploadState(isUploading: false, progress: nil)
      mediaVoiceButtonView.setDownloadState(
        needsDownload: false, isDownloading: false, progress: nil)
    }
    mediaVoiceButtonView.isUserInteractionEnabled = true
    mediaVideoHasAudio = false
    mediaVideoCurrentTime = 0.0
    mediaVideoTotalDuration = row.duration

    mediaTitleLabel.textColor = textColor
    mediaTitleLabel.textAlignment = .left
    mediaTitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
    mediaDetailLabel.textColor = metaColor
    mediaDetailLabel.textAlignment = .right
    mediaDetailLabel.font = UIFont.systemFont(ofSize: 11, weight: .regular)
    mediaContainerView.clipsToBounds = !isTransparentSticker
    mediaBorderLayer.isHidden = true
    mediaBorderLayer.lineWidth = 0.0
    mediaBorderLayer.strokeColor = nil
    mediaBorderLayer.path = nil
    let isFullBleedMedia = usesFullBleedMediaLayout(row)
    mediaContainerView.backgroundColor =
      isTransparentSticker ? .clear
      : isFullBleedMedia ? UIColor(white: 0.0, alpha: 0.28)
      : UIColor(white: 0.0, alpha: 0.16)
    mediaImageView.contentMode = isTransparentSticker ? .scaleAspectFit : .scaleAspectFill
    mediaImageView.clipsToBounds = !isTransparentSticker
    mediaImageView.layer.cornerRadius = 0.0

    do {
      let vkName: String
      switch row.visualKind {
      case .text: vkName = "text"
      case .voice: vkName = "voice"
      case .video: vkName = "video"
      case .videoNote: vkName = "videoNote"
      case .media: vkName = "media"
      case .document: vkName = "document"
      case .sticker: vkName = "sticker"
      }
      chatCellDebugLog(
        chatCellMediaDebugLogs,
        "[ChatMediaCfg] msgId=%@ type=%@ vk=%@ isGhost=%@ containerHidden=%@ containerAlpha=%.2f bubbleHidden=%@ fullBleed=%@ mediaUrl=%@",
        row.messageId ?? "-",
        row.messageType,
        vkName,
        isGhostHidden ? "Y" : "N",
        mediaContainerView.isHidden ? "Y" : "N",
        mediaContainerView.alpha,
        bubbleView.isHidden ? "Y" : "N",
        isFullBleedMedia ? "Y" : "N",
        (row.mediaUrl?.prefix(80)).map(String.init) ?? "nil"
      )
    }

    guard row.visualKind != .text else {
      mediaProgressOverlayView.isHidden = true
      mediaProgressRingView.setUploadState(isUploading: false, progress: nil)
      mediaProgressRingView.setDownloadState(needsDownload: false, isDownloading: false, progress: nil)
      mediaProgressSpinner.stopAnimating()
      mediaProgressSizeLabel.isHidden = true
      refreshViewOnceShineCover()
      return
    }

    mediaContainerView.clipsToBounds = true

    switch row.visualKind {
    case .voice:
      let usesMetadataLayout = usesAudioMetadataVoiceLayout(row)
      // Must NOT clip — VoicePlayProgressView's FluidVAD halo paints outside the plate.
      mediaContainerView.clipsToBounds = false
      mediaWaveformView.isHidden = usesMetadataLayout
      mediaDetailLabel.isHidden = false
      mediaDetailLabel.textAlignment = .left
      mediaContainerView.backgroundColor = .clear
      // Always hide the large media image for voice/music cells — cover sits on the play plate.
      mediaImageView.isHidden = true
      mediaImageView.image = nil
      mediaVoiceButtonView.clipsToBounds = false
      if usesMetadataLayout {
        // Register this track into the shared store/queue so the player sheet lists ALL of the
        // chat's music, not just the tapped one. Runs per rendered cell — independent of the
        // batch setRows path, which the cold-open cache paint skips (and which needs a chat id
        // the per-message payload often omits). Keyed on the list-stamped hostChatId fallback.
        if let musicChatId = effectiveHostChatId(for: row) {
          ChatAudioQueueRegistry.shared.registerMusicRow(row, chatId: musicChatId)
        } else {
          NSLog(
            "[MusicList] configure music msg=%@ NO chatId (row.chatId=%@ hostChatId=%@) — not registered",
            row.messageId ?? "-",
            row.chatId ?? "nil",
            hostChatId.isEmpty ? "empty" : hostChatId
          )
        }
        // Compact music cell: circular cover on play button + title/artist to the right.
        mediaPrimaryIconView.isHidden = true
        mediaVoiceButtonView.isHidden = false
        mediaTitleLabel.isHidden = false
        mediaTitleLabel.numberOfLines = 1
        mediaTitleLabel.textAlignment = .left
        mediaTitleLabel.lineBreakMode = .byTruncatingTail
        mediaDetailLabel.isHidden = false
        mediaDetailLabel.numberOfLines = 1
        mediaDetailLabel.textAlignment = .left
        mediaDetailLabel.lineBreakMode = .byTruncatingTail
        applyCompactMusicTextLabels(for: row)
        // Cover on the play plate (not a tall art card). A cold cache means "not yet",
        // so it never wipes a cover this cell is already showing for the same track.
        if let warm = chatMusicArtworkImage(for: row) {
          mediaVoiceButtonView.setArtworkImage(warm)
        }
        loadMusicCoverArtwork(for: row)
        // Plate background follows the theme (deep in dark, soft light in light) so it reads
        // behind the cover + VAD halo; white glyph/ring on play; accent-tinted download badge.
        let plateColor =
          appearance.isDark
          ? UIColor(white: 0.12, alpha: 1.0)
          : UIColor(white: 0.82, alpha: 1.0)
        mediaVoiceButtonView.applyStyle(
          fillColor: plateColor,
          iconTint: .white,
          ringTint: .white,
          badgeTint: appearance.accent
        )
      } else {
        mediaVoiceButtonView.isHidden = false
        mediaTitleLabel.isHidden = true
        mediaDetailLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        mediaDetailLabel.numberOfLines = 1
        mediaDetailLabel.text = "\(formatBubbleDuration(seconds: row.duration)) \u{2022}"
        mediaWaveformView.setWaveform(row.waveform)
        applyVoiceChromeColors(isMe: row.isMe)
      }
      let uploadProgress: CGFloat?
      if let value = row.uploadProgress, value.isFinite {
        uploadProgress = CGFloat(max(0.0, min(1.0, value)))
      } else {
        uploadProgress = nil
      }
      mediaVoiceButtonView.setUploadState(
        isUploading: row.shouldShowUploadOverlay,
        progress: uploadProgress
      )
      mediaVoiceButtonView.isUserInteractionEnabled = true
      refreshVoiceMetadataText()

    case .video:
      mediaImageView.isHidden = false
      refreshInlineVideoPlayGlyph()
      mediaContainerView.backgroundColor = UIColor(white: 0.0, alpha: 0.35)
      mediaBorderLayer.lineWidth = row.viewOnce ? 1.5 : 1.0
      mediaBorderLayer.strokeColor =
        appearance.accent.withAlphaComponent(
          row.viewOnce ? 0.92 : (appearance.isDark ? 0.48 : 0.38)
        ).cgColor
      mediaBorderLayer.isHidden = false

    case .videoNote:
      mediaImageView.isHidden = false
      // Soft center play only when not already playing inline (Telegram circle).
      refreshInlineVideoPlayGlyph()
      mediaContainerView.backgroundColor = UIColor(white: 0.0, alpha: 0.4)
      mediaBorderLayer.lineWidth = 0.0
      mediaBorderLayer.strokeColor = nil
      mediaBorderLayer.isHidden = true

    case .document:
      // بدونِ پس‌زمینه: تلگرام ردیفِ سند را مستقیم داخل حباب می‌چیند. یک جعبهٔ
      // گردِ دیگر داخل حباب، دو قاب تودرتو می‌سازد که همان چیزی است که چیدمان را
      // شلوغ و ناتمیز نشان می‌داد.
      mediaContainerView.backgroundColor = .clear
      mediaBorderLayer.lineWidth = 0.0
      mediaBorderLayer.isHidden = true
      mediaImageView.isHidden = false
      mediaImageView.contentMode = .scaleAspectFill
      mediaTitleLabel.isHidden = false
      mediaTitleLabel.textAlignment = .natural
      mediaTitleLabel.lineBreakMode = .byTruncatingMiddle
      mediaTitleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
      let documentTextColor = row.isMe ? appearance.textColorMe : appearance.textColorThem
      mediaTitleLabel.textColor = documentTextColor
      mediaTitleLabel.text = chatDocumentDisplayName(row)
      mediaDetailLabel.isHidden = false
      mediaDetailLabel.textAlignment = .natural
      mediaDetailLabel.lineBreakMode = .byTruncatingTail
      mediaDetailLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
      mediaDetailLabel.textColor = documentTextColor.withAlphaComponent(0.62)
      mediaDetailLabel.attributedText = documentDetailAttributedText(
        for: row, baseColor: documentTextColor, accent: appearance.accent)
      let hasPagePixels = mediaPixelQuality == .full && mediaImageView.image != nil
      // نشانِ نوعِ سند فقط وقتی دیده می‌شود که هنوز پیش‌نمایشی نداریم؛ روی
      // صفحهٔ رندرشده گذاشتنش، همان صفحه را می‌پوشاند.
      mediaPrimaryIconView.isHidden = hasPagePixels
      mediaPrimaryIconView.image = UIImage(
        systemName: chatDocumentGlyphName(row),
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .regular))
      mediaPrimaryIconView.tintColor = .white
      mediaPrimaryIconView.contentMode = .center
      mediaPrimaryIconView.backgroundColor = documentPlateColor(for: row, appearance: appearance)
      // Clamped + memoized thumb decode, so a legacy full-res base64 never decodes at
      // full size on main; pixels already on screen are never dropped for the scrim.
      if !hasPagePixels,
        let placeholder = chatDecodedMicroThumbnail(
          fromBase64: row.thumbnailBase64, cacheKey: "thumb-\(row.key)")
      {
        mediaImageView.image = placeholder
        mediaPixelQuality = .microThumb
        setMediaPlaceholderHidden(false)
      } else if !hasPagePixels {
        setMediaPlaceholderHidden(false)
      }

    case .media, .sticker:
      mediaImageView.isHidden = false
      mediaPrimaryIconView.isHidden = false
      let symbolName: String
      switch row.messageType {
      case "image", "gif", "sticker":
        symbolName = "photo.fill"
      case "file":
        symbolName = "doc.fill"
      default:
        symbolName = "paperclip"
      }
      mediaPrimaryIconView.image = UIImage(systemName: symbolName)?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 25, weight: .semibold))
      mediaPrimaryIconView.backgroundColor = .clear
      if row.messageType == "file" {
        mediaTitleLabel.isHidden = false
        mediaTitleLabel.text = row.fileName?.isEmpty == false ? row.fileName : "File"
        mediaTitleLabel.textAlignment = .center
        mediaImageView.isHidden = true
        mediaContainerView.backgroundColor = UIColor(white: 0.0, alpha: 0.28)
        resetStickerAnimation()
      } else if row.visualKind == .sticker {
        mediaPrimaryIconView.isHidden = true
        mediaContainerView.backgroundColor = .clear
        if configureStickerAnimation(for: row) {
          // Lottie loaded — hide static image
          mediaImageView.isHidden = true
        } else if row.mediaUrl == nil || row.mediaUrl?.isEmpty == true {
          mediaImageView.isHidden = true
          mediaTitleLabel.isHidden = true
          NSLog(
            "[ChatStickerCell] missing sticker asset msgId=%@ stickerId=%@ bundle=%@ packId=%@ mediaUrl=%@",
            row.messageId ?? "-",
            row.stickerId ?? "-",
            row.stickerBundleFileName ?? "-",
            row.stickerPackId ?? "-",
            row.mediaUrl ?? "-"
          )
        }
      } else {
        mediaPrimaryIconView.isHidden = true
      }
      if row.viewOnce, row.visualKind == .media, row.messageType != "file" {
        mediaBorderLayer.lineWidth = 1.5
        mediaBorderLayer.strokeColor = appearance.accent.withAlphaComponent(0.92).cgColor
        mediaBorderLayer.isHidden = false
      }

    case .text:
      break
    }

    configureMediaGrid(for: row)
    // Composer/agent sealed blobs + durable thumbs — always try to fill the hero so the
    // list never shows an empty media shell (even when a remote mediaUrl is present but
    // network hasn't finished; thumb paints first).
    if row.visualKind == .media, chatMediaGridImageCount(row) <= 1,
      mediaPixelQuality.rawValue < ChatMediaPreviewQuality.full.rawValue,
      chatOnDiskMediaFileURL(for: row) == nil,
      !row.agentBridgeAttachmentsEnc.isEmpty
        || !row.attachmentThumbnailsB64.isEmpty
        || (row.thumbnailBase64?.isEmpty == false)
    {
      mediaImageView.isHidden = false
      mediaPrimaryIconView.isHidden = true
      let rowKey = row.messageId ?? row.key
      let cacheKey = "\(rowKey)#hero-blob" as NSString
      // Prefer durable thumb SYNC so the first paint is never a solid plate; full sealed
      // blobs (larger) still decode async and promote.
      let thumbB64 = row.attachmentThumbnailsB64.first ?? row.thumbnailBase64
      if mediaPixelQuality.rawValue < ChatMediaPreviewQuality.microThumb.rawValue,
        let thumbImage = chatDecodedMicroThumbnail(
          fromBase64: thumbB64,
          cacheKey: "thumb-\(row.key)"
        )
      {
        applyResolvedMediaPreviewImage(
          thumbImage,
          for: row,
          mediaURL: row.mediaUrl ?? row.key,
          quality: .microThumb
        )
        chatRequestMicroThumbBlur(
          sharp: thumbImage, cacheKey: "thumb-\(row.key)"
        ) { [weak self] blurred in
          guard let self, (self.row?.messageId ?? self.row?.key) == rowKey else { return }
          self.applyResolvedMediaPreviewImage(
            blurred,
            for: row,
            mediaURL: row.mediaUrl ?? row.key,
            quality: .microThumb
          )
        }
      }
      if let cached = ChatListCell.bridgeGridImageCache.object(forKey: cacheKey) {
        applyResolvedMediaPreviewImage(
          cached,
          for: row,
          mediaURL: row.mediaUrl ?? row.key,
          quality: .full
        )
      } else if let firstBlob = row.agentBridgeAttachmentsEnc.first {
        ChatListCell.bridgeGridDecodeQueue.async { [weak self] in
          guard let image = ChatListCell.decodeBridgeGridImage(blob: firstBlob) else {
            return
          }
          ChatListCell.bridgeGridImageCache.setObject(image, forKey: cacheKey)
          DispatchQueue.main.async {
            guard let self, (self.row?.messageId ?? self.row?.key) == rowKey else { return }
            self.applyResolvedMediaPreviewImage(
              image,
              for: row,
              mediaURL: row.mediaUrl ?? row.key,
              quality: .full
            )
          }
        }
      }
    }

    chatCellDebugLog(
      chatCellMediaDebugLogs,
      "[ChatMediaCfg] POST-SWITCH msgId=%@ imgViewHidden=%@ imgViewImage=%@ containerBg=%@ containerFrame=%@",
      row.messageId ?? "-",
      mediaImageView.isHidden ? "Y" : "N",
      mediaImageView.image != nil ? "hasImage" : "nil",
      String(describing: mediaContainerView.backgroundColor),
      NSCoder.string(for: mediaContainerView.frame)
    )

    if mediaImageView.isHidden || row.mediaUrl == nil {
      if row.visualKind != .text && row.visualKind != .voice && row.visualKind != .sticker,
        !chatRowHasBridgeImageBlobsOnly(row)
      {
        chatCellDebugLog(
          chatCellMediaDebugLogs,
          "[ChatMediaLoad] SKIP-LOAD msgId=%@ type=%@ imgHidden=%@ mediaUrl=%@",
          row.messageId ?? "-",
          row.messageType,
          mediaImageView.isHidden ? "Y" : "N",
          row.mediaUrl == nil ? "nil" : (row.mediaUrl?.isEmpty == true ? "empty" : "present")
        )
      }
    }
    var preferredLocalMediaURL: String?
    // Image-like media must always enter the load path even if mediaImageView was left
    // hidden by a prior branch (empty shells were "photo" icons forever).
    let forceImageLoad =
      row.visualKind == .media && row.messageType != "file"
      || row.visualKind == .video || row.visualKind == .videoNote
    if forceImageLoad {
      mediaImageView.isHidden = false
    }
    // Set once this pass owns the on-disk file, so the ladder below does not decode the
    // same picture a second time.
    var resolvedFromDiskFile = false
    if forceImageLoad,
      mediaPixelQuality.rawValue < ChatMediaPreviewQuality.full.rawValue,
      let diskURL = chatOnDiskMediaFileURL(for: row)
    {
      let shouldAnimate = chatMediaShouldAnimate(
        urlString: diskURL.absoluteString, messageType: row.messageType)
      let diskKey = chatMediaCacheKey(diskURL.absoluteString, mediaKey: nil)
      let remoteKey = row.mediaUrl.map { chatMediaCacheKey($0, mediaKey: row.mediaKey) }
      let naturalSizeURL = row.mediaUrl ?? diskURL.absoluteString
      // Memory stays synchronous — that is what makes a second open instant. Only the file
      // read, the decode and any poster extraction leave the main thread.
      if let warm = chatMediaImageCache.object(forKey: diskKey as NSString)
        ?? remoteKey.flatMap({ chatMediaImageCache.object(forKey: $0 as NSString) })
      {
        applyResolvedMediaPreviewImage(warm, for: row, mediaURL: naturalSizeURL)
        mediaPrimaryIconView.isHidden = true
        preferredLocalMediaURL = diskURL.absoluteString
        resolvedFromDiskFile = true
      } else {
        let path = diskURL.path
        let posterIdentity = chatMediaRemoteIdentity(row) ?? remoteKey ?? diskKey
        resolveMediaImageOffMain(
          for: row,
          cacheKey: remoteKey ?? diskKey,
          naturalSizeURL: naturalSizeURL,
          storeKeys: row.viewOnce ? [] : ([diskKey] + (remoteKey.map { [$0] } ?? [])),
          decode: { maxPixelSize in
            chatMediaLoadImageFromFile(
              at: path, shouldAnimate: shouldAnimate, maxPixelSize: maxPixelSize,
              posterIdentity: posterIdentity)
          },
          onMiss: { [weak self] in
            ChatMediaWatchdog.once(
              key: "disk-unreadable:\(row.messageId ?? row.key)",
              "disk-unreadable msgId=\(row.messageId ?? row.key) path=\(path) remote=\(row.mediaUrl ?? "-")"
            )
            self?.loadUnreadableDiskMediaFromRemote(for: row)
          }
        )
        preferredLocalMediaURL = diskURL.absoluteString
        resolvedFromDiskFile = true
      }
    }
    // PDF pixels come only from PDFKit's page renderer in ChatListView. Keeping this
    // branch closed is the invariant that prevents a document from reaching UIImage
    // decode, the image editor, or the gallery cache.
    if row.visualKind != .document && (!mediaImageView.isHidden || forceImageLoad) {
      let prefersVideoPreview = row.visualKind == .video || row.visualKind == .videoNote
      // Sync micro-thumb first paint (Telegram): never leave a solid empty plate while
      // full media is still on disk/network. Decode is capped + cached (≤4KB wire thumbs).
      if mediaPixelQuality.rawValue < ChatMediaPreviewQuality.microThumb.rawValue
        || mediaImageView.image == nil
      {
        let thumbCacheKey = "thumb-\(row.key)"
        if let cachedThumb = chatMediaImageCache.object(forKey: thumbCacheKey as NSString) {
          applyResolvedMediaPreviewImage(
            cachedThumb,
            for: row,
            mediaURL: row.mediaUrl ?? row.key,
            quality: .microThumb
          )
          mediaPrimaryIconView.isHidden = true
          chatCellDebugLog(
            chatCellMediaDebugLogs,
            "[ChatMediaLoad] thumbnail memory OK msgId=%@ type=%@ hasUrl=%@",
            row.messageId ?? "-",
            row.messageType,
            row.mediaUrl == nil ? "N" : "Y"
          )
        } else {
          let thumbSource =
            row.thumbnailBase64
            ?? row.attachmentThumbnailsB64.first
          if let thumbnailImage = chatDecodedMicroThumbnail(
            fromBase64: thumbSource,
            cacheKey: thumbCacheKey
          ) {
            chatMediaImageCacheStore(thumbnailImage, forKey: thumbCacheKey)
            applyResolvedMediaPreviewImage(
              thumbnailImage,
              for: row,
              mediaURL: row.mediaUrl ?? row.key,
              quality: .microThumb
            )
            let blurRowKey = row.messageId ?? row.key
            chatRequestMicroThumbBlur(
              sharp: thumbnailImage, cacheKey: thumbCacheKey
            ) { [weak self] blurred in
              chatMediaImageCacheStore(blurred, forKey: thumbCacheKey)
              guard let self, (self.row?.messageId ?? self.row?.key) == blurRowKey else { return }
              self.applyResolvedMediaPreviewImage(
                blurred,
                for: row,
                mediaURL: row.mediaUrl ?? row.key,
                quality: .microThumb
              )
            }
            mediaPrimaryIconView.isHidden = true
            chatCellDebugLog(
              chatCellMediaDebugLogs,
              "[ChatMediaLoad] thumbnail metadata OK msgId=%@ type=%@ hasUrl=%@",
              row.messageId ?? "-",
              row.messageType,
              row.mediaUrl == nil ? "N" : "Y"
            )
          } else if !prefersVideoPreview,
            let diskURL = chatOnDiskMediaFileURL(for: row),
            !chatMediaShouldAnimate(urlString: diskURL.absoluteString, messageType: row.messageType),
            let diskThumb = chatMediaLoadImageFromFile(at: diskURL.path, shouldAnimate: false, maxPixelSize: 128)
          {
            // No wire thumb yet (older senders / mid-flight uploads): bridge a capped sync
            // decode from the vault file so first paint is not a solid empty plate.
            chatMediaImageCacheStore(diskThumb, forKey: thumbCacheKey)
            applyResolvedMediaPreviewImage(
              diskThumb,
              for: row,
              mediaURL: row.mediaUrl ?? row.key,
              quality: .microThumb
            )
            mediaPrimaryIconView.isHidden = true
          }
        }
      }
      preferredLocalMediaURL = {
        if let override = preferredLocalMediaURLOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
          !override.isEmpty
        {
          let overridePath: String
          if let parsed = URL(string: override), parsed.isFileURL {
            overridePath = parsed.path
          } else {
            overridePath = override
          }
          if FileManager.default.fileExists(atPath: overridePath) {
            return override
          }
        }
        guard
          row.visualKind == .media || row.visualKind == .sticker || row.visualKind == .video
            || row.visualKind == .videoNote,
          let localMediaUrl = row.localMediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
          !localMediaUrl.isEmpty
        else {
          return nil
        }
        let localPath: String
        if let parsed = URL(string: localMediaUrl), parsed.isFileURL {
          localPath = parsed.path
        } else {
          localPath = localMediaUrl
        }
        guard FileManager.default.fileExists(atPath: localPath) else { return nil }
        return localMediaUrl
      }()
      if !resolvedFromDiskFile, let urlStr = preferredLocalMediaURL ?? row.mediaUrl {
        let effectiveMediaKey = preferredLocalMediaURL == nil ? row.mediaKey : nil
        let cacheKey = chatMediaCacheKey(urlStr, mediaKey: effectiveMediaKey)
        let shortUrl = urlStr.count > 80 ? String(urlStr.prefix(77)) + "..." : urlStr
        let encodedUrlStr =
          urlStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlStr
        let shouldAnimateMedia = chatMediaShouldAnimate(
          urlString: urlStr,
          messageType: row.messageType
        )
        let naturalSizeURL = row.mediaUrl ?? urlStr
        if let url = URL(string: urlStr) ?? URL(string: encodedUrlStr) {
          let isLocal = url.isFileURL || urlStr.hasPrefix("/")
          let rawURLKey = chatMediaLegacyCacheKey(urlStr, mediaKey: effectiveMediaKey)
          let hasPreferredLocal = preferredLocalMediaURL != nil
          if chatCellMediaDebugLogs {
            // Built only when logging is on — the vault probe is a stat per media cell.
            let inMemory = chatMediaImageCache.object(forKey: cacheKey as NSString) != nil
            let onDisk = isLocal ? false : VibeMediaVault.shared.contains(cacheKey, kind: .image)
            chatCellDebugLog(
              chatCellMediaDebugLogs,
              "[ChatMediaLoad] RESOLVE msgId=%@ inMemory=%@ isLocal=%@ onDisk=%@ isFailed=%@ animate=%@ url=%@",
              row.messageId ?? "-",
              inMemory ? "Y" : "N",
              isLocal ? "Y" : "N",
              onDisk ? "Y" : "N",
              chatMediaFailedURLs.contains(rawURLKey) ? "Y" : "N",
              shouldAnimateMedia ? "Y" : "N",
              shortUrl
            )
          }
          if let cachedImage = chatMediaImageCache.object(forKey: cacheKey as NSString) {
            applyResolvedMediaPreviewImage(cachedImage, for: row, mediaURL: naturalSizeURL)
          } else if isLocal {
            let path = url.isFileURL ? url.path : urlStr
            let posterIdentity = chatMediaRemoteIdentity(row) ?? cacheKey
            resolveMediaImageOffMain(
              for: row,
              cacheKey: cacheKey,
              naturalSizeURL: naturalSizeURL,
              storeKeys: row.viewOnce ? [] : [cacheKey],
              decode: { maxPixelSize in
                if let image = chatMediaLoadImageFromFile(
                  at: path, shouldAnimate: shouldAnimateMedia, maxPixelSize: maxPixelSize,
                  posterIdentity: posterIdentity)
                {
                  return image
                }
                // Diagnostics stay on this queue — the header read is file IO.
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                chatCellDebugLog(
                  chatCellMediaDebugLogs,
                  "[ChatMediaLoad] local file NO_PREVIEW msgId=%@ type=%@ bytes=%lld path=%@ hasMediaKey=%@ fileName=%@ header=%@",
                  row.messageId ?? "-",
                  row.messageType,
                  (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
                  path,
                  (row.mediaKey?.isEmpty == false) ? "Y" : "N",
                  row.fileName ?? "-",
                  chatMediaFileHeaderSummary(at: path)
                )
                return nil
              }
            )
          } else if row.viewOnce {
            loadRemoteMediaPreviewIfNeeded(
              for: row, url: url, urlStr: urlStr, cacheKey: cacheKey, rawURLKey: rawURLKey,
              mediaKey: effectiveMediaKey, shouldAnimate: shouldAnimateMedia,
              prefersVideoPreview: prefersVideoPreview, naturalSizeURL: naturalSizeURL,
              hasPreferredLocalMedia: hasPreferredLocal)
          } else {
            resolveMediaImageOffMain(
              for: row,
              cacheKey: cacheKey,
              naturalSizeURL: naturalSizeURL,
              storeKeys: [cacheKey],
              decode: { maxPixelSize in
                guard let diskData = chatMediaDiskCacheLoad(cacheKey, legacyRawKey: rawURLKey)
                else { return nil }
                return chatMediaPreviewImage(
                  from: diskData,
                  shouldAnimate: shouldAnimateMedia,
                  cacheKey: cacheKey,
                  urlString: urlStr,
                  fileName: row.fileName,
                  messageType: row.messageType,
                  preferVideoPreview: prefersVideoPreview,
                  maxPixelSize: maxPixelSize
                )
              },
              onMiss: { [weak self] in
                self?.loadRemoteMediaPreviewIfNeeded(
                  for: row, url: url, urlStr: urlStr, cacheKey: cacheKey, rawURLKey: rawURLKey,
                  mediaKey: effectiveMediaKey, shouldAnimate: shouldAnimateMedia,
                  prefersVideoPreview: prefersVideoPreview, naturalSizeURL: naturalSizeURL,
                  hasPreferredLocalMedia: hasPreferredLocal)
              }
            )
          }
        } else {
          chatCellDebugLog(
            chatCellMediaDebugLogs,
            "[ChatMediaLoad] URL parse FAIL msgId=%@ raw=%@", row.messageId ?? "-", shortUrl)
        }
      }
    }

    configureVideoInfoBadge(for: row, preferredLocalMediaURL: preferredLocalMediaURL)
    refreshInlineVideoPlaybackIfNeeded(preferredLocalMediaURL: preferredLocalMediaURL)

    if row.visualKind == .voice {
      stopInlineVideoPlayback(resetMutedState: true)
      mediaProgressOverlayView.isHidden = true
      mediaProgressRingView.setUploadState(isUploading: false, progress: nil)
      mediaProgressRingView.setDownloadState(needsDownload: false, isDownloading: false, progress: nil)
      mediaProgressSpinner.stopAnimating()
      mediaProgressSizeLabel.isHidden = true
      updateMediaPlaceholderVisibility()
      refreshViewOnceShineCover()
      return
    }

    updateMediaTransferChrome(for: row)
    updateMediaPlaceholderVisibility()

    chatCellDebugLog(
      chatCellMediaDebugLogs,
      "[ChatMediaCfg] FINAL msgId=%@ imgHidden=%@ hasImg=%@ containerHidden=%@ containerAlpha=%.2f containerBg=%@ containerFrame=%@",
      row.messageId ?? "-",
      mediaImageView.isHidden ? "Y" : "N",
      mediaImageView.image != nil ? "Y" : "N",
      mediaContainerView.isHidden ? "Y" : "N",
      mediaContainerView.alpha,
      String(describing: mediaContainerView.backgroundColor),
      NSCoder.string(for: mediaContainerView.frame)
    )
    // [MediaPop] a visible media cell finishing configure WITHOUT pixels will paint a
    // blank shell this frame and pop when its async decode/download lands — name the
    // row and which sources it has, so device logs identify the flicker population.
    if window != nil, !mediaImageView.isHidden, mediaImageView.image == nil,
      row.visualKind == .media || row.visualKind == .video || row.visualKind == .videoNote
    {
      NSLog(
        "[MediaPop] blank-paint msgId=%@ type=%@ thumbB64=%@ blob=%@ localUrl=%@ url=%@",
        row.messageId ?? row.key, row.messageType,
        (row.thumbnailBase64?.isEmpty == false || !row.attachmentThumbnailsB64.isEmpty)
          ? "Y" : "N",
        row.agentBridgeAttachmentsEnc.isEmpty ? "N" : "Y",
        (row.localMediaUrl?.isEmpty == false) ? "Y" : "N",
        (row.mediaUrl?.isEmpty == false) ? "Y" : "N")
    }
    updateStickerAnimationPlayback()
    refreshViewOnceShineCover()
  }

  /// One file read + decode off main, promoted through the promote-only apply. Callers keep
  /// the memory lookup synchronous; `onMiss` runs on main after the same identity check.
  private func resolveMediaImageOffMain(
    for row: ChatListRow,
    cacheKey: String,
    naturalSizeURL: String,
    storeKeys: [String],
    decode: @escaping (Int) -> UIImage?,
    onMiss: (() -> Void)? = nil
  ) {
    guard mediaDecodeInFlightKey != cacheKey else { return }
    mediaDecodeInFlightKey = cacheKey
    let rowKey = row.messageId ?? row.key
    let maxPixelSize = chatMediaBubbleDecodeMaxPixelSize()
    chatMediaDiskCacheQueue.async { [weak self] in
      let image = decode(maxPixelSize)
      if let image {
        for key in storeKeys {
          chatMediaImageCacheStore(image, forKey: key)
        }
      }
      DispatchQueue.main.async {
        guard let self else { return }
        if self.mediaDecodeInFlightKey == cacheKey {
          self.mediaDecodeInFlightKey = nil
        }
        guard let currentRow = self.row,
          (currentRow.messageId ?? currentRow.key) == rowKey,
          chatMediaRowsShareRemoteIdentity(currentRow, row)
        else { return }
        guard let image else {
          onMiss?()
          return
        }
        self.applyResolvedMediaPreviewImage(image, for: row, mediaURL: naturalSizeURL)
        self.mediaPrimaryIconView.isHidden = true
      }
    }
  }

  /// The on-disk copy could not be decoded — fall back to the remote bytes, if any.
  private func loadUnreadableDiskMediaFromRemote(for row: ChatListRow) {
    guard let raw = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
      let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else { return }
    let cacheKey = chatMediaCacheKey(raw, mediaKey: row.mediaKey)
    loadRemoteMediaPreviewIfNeeded(
      for: row,
      url: url,
      urlStr: raw,
      cacheKey: cacheKey,
      rawURLKey: chatMediaLegacyCacheKey(raw, mediaKey: row.mediaKey),
      mediaKey: row.mediaKey,
      shouldAnimate: chatMediaShouldAnimate(urlString: raw, messageType: row.messageType),
      prefersVideoPreview: row.visualKind == .video || row.visualKind == .videoNote,
      naturalSizeURL: raw,
      hasPreferredLocalMedia: false
    )
  }

  /// Tail of the preview ladder — reached on main once every on-disk source has missed.
  /// Decode of the downloaded bytes happens on the session's own queue, never on main.
  private func loadRemoteMediaPreviewIfNeeded(
    for row: ChatListRow,
    url: URL,
    urlStr: String,
    cacheKey: String,
    rawURLKey: String,
    mediaKey: String?,
    shouldAnimate: Bool,
    prefersVideoPreview: Bool,
    naturalSizeURL: String,
    hasPreferredLocalMedia: Bool
  ) {
    let shortUrl = urlStr.count > 80 ? String(urlStr.prefix(77)) + "..." : urlStr
    guard !chatMediaFailedURLs.contains(rawURLKey) else {
      chatCellDebugLog(
        chatCellMediaDebugLogs,
        "[ChatMediaLoad] skipping previously failed url=%@",
        shortUrl
      )
      return
    }
    guard !(skipRemoteMediaLoad && !hasPreferredLocalMedia) else {
      chatCellDebugLog(
        chatCellMediaDebugLogs,
        "[ChatMediaLoad] SKIP-REMOTE-PREVIEW msgId=%@ type=%@ url=%@",
        row.messageId ?? "-",
        row.messageType,
        urlStr
      )
      return
    }
    // The same download is never started twice for one cell; a different one replaces it.
    guard mediaImageTask == nil || mediaImageTaskKey != cacheKey else { return }
    mediaImageTask?.cancel()
    chatCellDebugLog(
      chatCellMediaDebugLogs,
      "[ChatMediaLoad] network fetch START msgId=%@ url=%@", row.messageId ?? "-", shortUrl)
    let rowKey = row.messageId ?? row.key
    let maxPixelSize = chatMediaBubbleDecodeMaxPixelSize()
    mediaImageTaskKey = cacheKey
    mediaImageTask = VibeHTTP.shared.dataTask(with: url) {
      [weak self] data, response, error in
      func clearTask(_ cell: ChatListCell?) {
        DispatchQueue.main.async {
          guard let cell, cell.mediaImageTaskKey == cacheKey else { return }
          cell.mediaImageTask = nil
          cell.mediaImageTaskKey = nil
        }
      }
      if let error {
        let nsErr = error as NSError
        let isCancelled = nsErr.code == NSURLErrorCancelled
        chatCellDebugLog(
          chatCellMediaDebugLogs,
          "[ChatMediaLoad] network fetch FAIL msgId=%@ error=%@ cancelled=%@",
          row.messageId ?? "-", error.localizedDescription, isCancelled ? "Y" : "N")
        if !isCancelled {
          let count = (chatMediaRetryCount[rawURLKey] ?? 0) + 1
          chatMediaRetryCount[rawURLKey] = count
          if count >= chatMediaMaxRetries {
            chatMediaFailedURLs.insert(rawURLKey)
          }
        }
        clearTask(self)
        return
      }
      guard let self = self, let data = data else {
        clearTask(self)
        return
      }
      // Always try: (1) mediaKey decrypt (2) raw bytes (3) strip any wrapper.
      // Wrong/stale mediaKey previously left empty cells forever when only (1) ran.
      let decrypted = chatMediaDecryptedDataIfNeeded(data, mediaKey: mediaKey)
      var candidates: [Data] = []
      if let decrypted { candidates.append(decrypted) }
      if decrypted == nil || decrypted?.count != data.count || decrypted != data {
        candidates.append(data)
      }
      // Dedup by count+prefix so we don't decode the same buffer twice.
      var seen = Set<String>()
      candidates = candidates.filter { d in
        let sig =
          "\(d.count):\(d.prefix(8).map { String(format: "%02x", $0) }.joined())"
        return seen.insert(sig).inserted
      }
      var previewImage: UIImage?
      var safeData: Data?
      for candidate in candidates {
        if let image = chatMediaPreviewImage(
          from: candidate,
          shouldAnimate: shouldAnimate,
          cacheKey: cacheKey,
          urlString: urlStr,
          fileName: row.fileName,
          messageType: row.messageType,
          preferVideoPreview: prefersVideoPreview,
          maxPixelSize: maxPixelSize
        ) {
          previewImage = image
          safeData = candidate
          break
        }
      }
      guard let image = previewImage, let safeData else {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let bodyPreview = String(data: data, encoding: .utf8) ?? "nil"
        chatCellDebugLog(
          chatCellMediaDebugLogs,
          "[ChatMediaLoad] network fetch NO_PREVIEW msgId=%@ type=%@ dataLen=%d status=%d url=%@ fileName=%@ hasThumb=%@ body=%@ header=%@",
          row.messageId ?? "-",
          row.messageType,
          data.count,
          statusCode,
          urlStr,
          row.fileName ?? "-",
          row.thumbnailBase64 == nil ? "N" : "Y",
          String(bodyPreview.prefix(200)),
          chatMediaHeaderSummary(from: decrypted ?? data))
        // Don't permanent-fail if we at least have a durable thumb — cell can show it.
        if row.thumbnailBase64 == nil && row.attachmentThumbnailsB64.isEmpty {
          chatMediaFailedURLs.insert(rawURLKey)
        }
        clearTask(self)
        return
      }
      chatCellDebugLog(
        chatCellMediaDebugLogs,
        "[ChatMediaLoad] network fetch OK msgId=%@ type=%@ bytes=%d url=%@",
        row.messageId ?? "-",
        row.messageType,
        safeData.count,
        shortUrl
      )
      if !row.viewOnce {
        chatMediaImageCacheStore(image, forKey: cacheKey)
        chatMediaDiskCacheSave(safeData, forKey: cacheKey)
      } else {
        chatViewOnceCacheSealed(image, key: row.messageId ?? row.key)
      }
      DispatchQueue.main.async {
        if self.mediaImageTaskKey == cacheKey {
          self.mediaImageTask = nil
          self.mediaImageTaskKey = nil
        }
        guard
          let currentRow = self.row,
          (currentRow.messageId ?? currentRow.key) == rowKey,
          currentRow.mediaUrl == row.mediaUrl,
          currentRow.localMediaUrl == row.localMediaUrl,
          currentRow.mediaKey == row.mediaKey
        else { return }
        self.applyResolvedMediaPreviewImage(image, for: row, mediaURL: naturalSizeURL)
        self.mediaPrimaryIconView.isHidden = true
      }
    }
    mediaImageTask?.resume()
  }

  private func reportNaturalMediaSizeIfNeeded(
    for row: ChatListRow, mediaURL: String, image: UIImage
  ) {
    let size = image.size
    guard size.width > 1.0, size.height > 1.0 else { return }
    cacheNaturalMediaSize(size, for: mediaURL)
    // Teach it under the ROW's url as well, because that is the one the sizing path asks
    // with — and it is frequently not this one.
    //
    // `mediaURL` here is whatever the cell actually loaded: a local file in the container,
    // a vault path, a signed URL. `resolvedMediaNaturalSize` looks the size up by
    // `row.mediaUrl`. When those two normalize to different identities the durable store
    // records a size nobody ever asks for, and the row is forecast as a SQUARE on every
    // single open, forever. Device run 2026-08-04, chat 47157fce5863: the store had 23
    // entries and `seed-forecast squareMedia=5` on every reopen, each one correcting
    // `was=412 now=612` — a 200pt jump under the reader's thumb, repeatedly, for photos
    // the app had already measured many times.
    if let rowMediaURL = row.mediaUrl, rowMediaURL != mediaURL {
      cacheNaturalMediaSize(size, for: rowMediaURL)
    }
    let sizeKey = "\(mediaURL)|\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    if lastReportedMediaSizeKey == sizeKey {
      return
    }
    lastReportedMediaSizeKey = sizeKey
    onMediaNaturalSizeResolved?(row.messageId, mediaURL, size)
  }

  /// [MediaPop] configure-pass stamp — see `configure` and applyResolvedMediaPreviewImage.
  private var lastConfigureStartedAt: TimeInterval = 0

  private func applyResolvedMediaPreviewImage(
    _ image: UIImage,
    for row: ChatListRow,
    mediaURL: String,
    quality: ChatMediaPreviewQuality = .full
  ) {
    // Promote-only: a micro-thumb must never clobber full media, and a stale late
    // thumb after full download is a no-op.
    if quality.rawValue < mediaPixelQuality.rawValue {
      return
    }
    // Every resolved preview lands here. An apply well after the synchronous configure
    // pass, on a cell the user can see, IS the visible image pop — name it.
    let sinceConfigureMs = Int(
      (ProcessInfo.processInfo.systemUptime - lastConfigureStartedAt) * 1000)
    if window != nil, sinceConfigureMs > 50, quality == .full {
      NSLog(
        "[MediaPop] late-image msgId=%@ type=%@ sinceCfgMs=%d hadImage=%@ quality=%d",
        row.messageId ?? row.key, row.messageType, sinceConfigureMs,
        mediaImageView.image != nil ? "Y" : "N", quality.rawValue)
    }
    mediaPixelQuality = quality
    if row.visualKind == .media || row.visualKind == .video || row.visualKind == .videoNote {
      mediaPrimaryIconView.isHidden = true
    }
    if quality == .full {
      reportNaturalMediaSizeIfNeeded(for: row, mediaURL: mediaURL, image: image)
    }
    if row.viewOnce, shouldShowViewOnceShineCover(row) {
      let key = row.messageId ?? row.key
      chatViewOnceCacheSealed(image, key: key)
      let concealed = chatViewOnceConcealedStill(from: image, cacheKey: key)
      mediaImageView.image = concealed
      mediaImageView.isHidden = false
      if quality == .full,
        let metrics = cachedLayoutMetrics,
        metrics.isMediaLayout, usesFullBleedMediaLayout(row)
      {
        tailView.setImage(concealed)
        tailView.isHidden = isGhostHidden || !row.shape.showTail
      }
      updateMediaPlaceholderVisibility()
      refreshViewOnceShineCover()
      return
    }
    mediaImageView.image = image
    mediaImageView.isHidden = false
    updateMediaPlaceholderVisibility()
    if quality == .full,
      let metrics = cachedLayoutMetrics,
      metrics.isMediaLayout, usesFullBleedMediaLayout(row)
    {
      tailView.setImage(image)
      tailView.isHidden = isGhostHidden || !row.shape.showTail
    }
    refreshViewOnceShineCover()
  }

  private func layoutMediaSubviews(for row: ChatListRow, in bounds: CGRect) {
    let width = bounds.width
    let height = bounds.height
    let appearanceShape = chatAppearanceBubbleShape(row.shape, appearance: appearance)

    let isTransparentSticker = isTransparentStickerMessage(row)
    let isFullBleed = usesFullBleedMediaLayout(row)
    let cornerRadius: CGFloat
    switch row.visualKind {
    case .videoNote:
      cornerRadius = floor(min(width, height) * 0.5)
    case .voice:
      cornerRadius = 10.0
    default:
      cornerRadius = 12.0
    }

    if isTransparentSticker {
      mediaContainerView.layer.cornerRadius = 0.0
      mediaContainerView.layer.mask = nil
    } else if isFullBleed {
      if row.visualKind == .videoNote {
        mediaContainerView.layer.cornerRadius = floor(min(width, height) * 0.5)
        mediaContainerView.layer.mask = nil
      } else {
        mediaContainerView.layer.cornerRadius = 0.0
        fullBleedMaskLayer.frame = mediaContainerView.bounds
        fullBleedMaskLayer.path =
          bubbleRoundedPath(
            rect: mediaContainerView.bounds,
            topLeft: appearanceShape.borderTopLeftRadius,
            topRight: appearanceShape.borderTopRightRadius,
            bottomRight: appearanceShape.borderBottomRightRadius,
            bottomLeft: appearanceShape.borderBottomLeftRadius
          ).cgPath
        mediaContainerView.layer.mask = fullBleedMaskLayer
      }
    } else if usesEdgeMediaCaptionLayout(row) {
      // Media reads as the bubble's top face: outer top corners follow the bubble's own
      // radii minus the hairline inset; bottom corners stay tight above the caption.
      mediaContainerView.layer.cornerRadius = 0.0
      fullBleedMaskLayer.frame = mediaContainerView.bounds
      fullBleedMaskLayer.path =
        bubbleRoundedPath(
          rect: mediaContainerView.bounds,
          topLeft: max(2.0, appearanceShape.borderTopLeftRadius - mediaCaptionEdgeInset),
          topRight: max(2.0, appearanceShape.borderTopRightRadius - mediaCaptionEdgeInset),
          bottomRight: 5.0,
          bottomLeft: 5.0
        ).cgPath
      mediaContainerView.layer.mask = fullBleedMaskLayer
    } else {
      mediaContainerView.layer.cornerRadius = cornerRadius
      mediaContainerView.layer.mask = nil
    }
    // Sizing an unbuilt view is what a lazy view exists to avoid, and `layoutSubviews`
    // is the hottest path in the cell — every scroll tick, for every mounted row.
    if let scrim = _mediaPlaceholderBlurView {
      scrim.frame = mediaContainerView.bounds
      _mediaPlaceholderTintView?.frame = scrim.contentView.bounds
    }
    if let cover = _viewOnceShineCover {
      cover.frame = mediaContainerView.bounds
      if !cover.isHidden {
        mediaContainerView.insertSubview(cover, belowSubview: mediaPrimaryIconView)
      }
    }
    mediaVideoPlayerHostView.frame = mediaContainerView.bounds
    _mediaVideoPlayerLayer?.frame = mediaVideoPlayerHostView.bounds
    mediaProgressOverlayView.layer.cornerRadius = 0.0
    mediaBorderLayer.frame = mediaContainerView.bounds
    if !mediaBorderLayer.isHidden && mediaBorderLayer.lineWidth > 0.0 {
      let borderInset = mediaBorderLayer.lineWidth * 0.5
      let borderBounds = mediaContainerView.bounds.insetBy(dx: borderInset, dy: borderInset)
      if row.visualKind == .videoNote {
        mediaBorderLayer.path = UIBezierPath(ovalIn: borderBounds).cgPath
      } else if isFullBleed {
        mediaBorderLayer.path =
          bubbleRoundedPath(
            rect: borderBounds,
            topLeft: max(0.0, appearanceShape.borderTopLeftRadius - borderInset),
            topRight: max(0.0, appearanceShape.borderTopRightRadius - borderInset),
            bottomRight: max(0.0, appearanceShape.borderBottomRightRadius - borderInset),
            bottomLeft: max(0.0, appearanceShape.borderBottomLeftRadius - borderInset)
          ).cgPath
      } else {
        mediaBorderLayer.path =
          UIBezierPath(
            roundedRect: borderBounds,
            cornerRadius: max(0.0, cornerRadius - borderInset)
          ).cgPath
      }
    }

    mediaPrimaryIconView.frame = .zero
    mediaVoiceButtonView.frame = .zero
    mediaWaveformView.frame = .zero
    mediaTitleLabel.frame = .zero
    mediaDetailLabel.frame = .zero
    mediaVideoInfoBadgeView.frame = .zero
    mediaVideoTimeIconView.frame = .zero
    mediaVideoAudioIconView.frame = .zero
    mediaDurationBadge.frame = .zero
    mediaProgressOverlayView.frame = .zero
    mediaProgressRingView.frame = .zero
    mediaProgressSpinner.frame = .zero
    mediaProgressSizeLabel.frame = .zero

    switch row.visualKind {
    case .voice:
      // Inset the play plate so the FluidVAD halo (which paints outside the plate)
      // is not clipped by the bubble edge or a hard left bound.
      let edgePad: CGFloat = 5.0
      let buttonSize: CGFloat = min(52.0, max(40.0, height - edgePad * 2.0))
      mediaVoiceButtonView.frame = CGRect(
        x: edgePad,
        y: floor((height - buttonSize) * 0.5),
        width: buttonSize,
        height: buttonSize
      )
      let textStartX = mediaVoiceButtonView.frame.maxX + 8.0
      let rightInset: CGFloat = 8.0
      let textW = max(1.0, width - textStartX - rightInset)
      if usesAudioMetadataVoiceLayout(row) {
        // Compact music cell: play (with cover + VAD) | title / artist
        mediaImageView.frame = .zero
        mediaImageView.isHidden = true
        mediaTitleLabel.frame = CGRect(x: textStartX, y: 12.0, width: textW, height: 18.0)
        mediaDetailLabel.frame = CGRect(
          x: textStartX,
          y: mediaTitleLabel.frame.maxY + 2.0,
          width: textW,
          height: 16.0
        )
        mediaWaveformView.frame = .zero
      } else {
        let waveY: CGFloat = 10.0
        let waveHeight: CGFloat = 20.0
        // Wider while downloading so "2.3 MB / 7.8 MB" captions are not clipped.
        let detailWidth: CGFloat =
          mediaIsDownloading
          ? max(50.0, min(160.0, width - textStartX - rightInset))
          : 50.0
        mediaDetailLabel.frame = CGRect(
          x: textStartX,
          y: waveY + waveHeight + 4.0,
          width: detailWidth,
          height: 14.0
        )
        mediaWaveformView.frame = CGRect(
          x: textStartX,
          y: waveY,
          width: max(1.0, width - textStartX - rightInset),
          height: waveHeight
        )
      }

    case .document:
      // نسبت‌های تلگرام: تصویرِ بزرگ و مربع در لبه، متن کنارش با یک خط فاصله،
      // و هیچ حاشیهٔ اضافه‌ای که ردیف را از حباب جدا نشان بدهد.
      let previewSide = max(44.0, height - documentRowVerticalInset * 2.0)
      let previewFrame = CGRect(
        x: 0.0,
        y: floor((height - previewSide) * 0.5),
        width: previewSide,
        height: previewSide
      )
      mediaImageView.frame = previewFrame
      if let scrim = _mediaPlaceholderBlurView {
        scrim.frame = previewFrame
        _mediaPlaceholderTintView?.frame = scrim.contentView.bounds
      }
      mediaImageView.layer.cornerRadius = documentPreviewCornerRadius
      mediaImageView.layer.cornerCurve = .continuous
      mediaPrimaryIconView.frame = previewFrame
      mediaPrimaryIconView.layer.cornerRadius = documentPreviewCornerRadius
      mediaPrimaryIconView.layer.cornerCurve = .continuous

      // چرخِ پیشرفت روی خودِ تصویر می‌نشیند — همان جایی که کاربر برای دانلود
      // یا لغو ضربه می‌زند. بی‌قید‌و‌شرط: قابِ پوشش را فقط دیده‌شدنش تعیین می‌کند
      // (applyMediaTransferState)، و اگر این‌جا قاب نگیرد، صفر می‌ماند و حلقه ناپدید
      // می‌شود.
      mediaProgressOverlayView.frame = previewFrame
      let ringSize: CGFloat = min(36.0, previewSide - 16.0)
      mediaProgressRingView.frame = CGRect(
        x: floor((previewSide - ringSize) * 0.5),
        y: floor((previewSide - ringSize) * 0.5),
        width: ringSize,
        height: ringSize
      )
      mediaProgressSpinner.center = CGPoint(x: previewSide * 0.5, y: previewSide * 0.5)

      let textX = previewFrame.maxX + 12.0
      let textWidth = max(1.0, width - textX)
      let titleHeight: CGFloat = 21.0
      let detailHeight: CGFloat = 18.0
      let stackHeight = titleHeight + 2.0 + detailHeight
      let stackTop = floor((height - stackHeight) * 0.5)
      mediaTitleLabel.frame = CGRect(
        x: textX, y: stackTop, width: textWidth, height: titleHeight)
      mediaDetailLabel.frame = CGRect(
        x: textX, y: mediaTitleLabel.frame.maxY + 2.0, width: textWidth, height: detailHeight)

    case .video, .videoNote, .media, .sticker:
      let btnSize: CGFloat = 44.0
      mediaPrimaryIconView.frame = CGRect(
        x: floor((width - btnSize) * 0.5),
        y: floor((height - btnSize) * 0.5),
        width: btnSize,
        height: btnSize
      )
      mediaPrimaryIconView.layer.cornerRadius = btnSize * 0.5
      mediaContainerView.bringSubviewToFront(mediaPrimaryIconView)

      if row.visualKind == .videoNote {
        // Only the mute pill rides the circle; the duration capsule sits on the wallpaper
        // under the note, level with the time, since the circular clip cuts anything else.
        let mutePillHeight: CGFloat = 20.0
        let mutePillWidth: CGFloat = 30.0
        if mediaVideoAudioIconView.superview !== mediaContainerView {
          mediaContainerView.addSubview(mediaVideoAudioIconView)
        }
        mediaVideoAudioIconView.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        mediaVideoAudioIconView.layer.cornerRadius = mutePillHeight * 0.5
        mediaVideoAudioIconView.layer.cornerCurve = .continuous
        mediaVideoAudioIconView.clipsToBounds = true
        mediaVideoAudioIconView.tintColor = .white
        mediaVideoAudioIconView.contentMode = .center
        mediaVideoAudioIconView.frame =
          mediaVideoAudioIconView.isHidden
          ? .zero
          : CGRect(
            x: floor((width - mutePillWidth) * 0.5),
            y: floor(height * 0.9 - mutePillHeight * 0.5),
            width: mutePillWidth,
            height: mutePillHeight)
        mediaVideoTimeIconView.frame = .zero
        mediaContainerView.bringSubviewToFront(mediaVideoAudioIconView)

        if mediaVideoInfoBadgeView.superview !== contentView {
          contentView.addSubview(mediaVideoInfoBadgeView)
        }
        let noteFrame = mediaContainerView.frame
        let metaLine = metaContainerView.frame
        let badgeHeight = metaLine.height > 1.0 ? metaLine.height : bubbleMetaHeight
        let badgeY = metaLine.height > 1.0 ? metaLine.minY : noteFrame.maxY + 4.0
        mediaDurationBadge.textColor = timestampLabel.textColor
        mediaDurationBadge.font = .systemFont(ofSize: 11, weight: .semibold)
        mediaDurationBadge.layer.shadowOpacity = 0.0
        mediaDurationBadge.textAlignment = .left
        let textWidth = measuredTextWidth(
          mediaDurationBadge.text ?? "", font: mediaDurationBadge.font)
        let badgeWidth = max(24.0, ceil(textWidth) + 2.0)
        mediaVideoInfoBadgeView.backgroundColor = .clear
        mediaVideoInfoBadgeView.layer.cornerRadius = 0.0
        mediaVideoInfoBadgeView.clipsToBounds = false
        mediaVideoInfoBadgeView.frame = CGRect(
          x: noteFrame.minX + 4.0,
          y: badgeY,
          width: badgeWidth,
          height: badgeHeight
        )
        mediaDurationBadge.frame = CGRect(
          x: 0.0, y: 0.0, width: badgeWidth, height: badgeHeight)
      } else if !mediaVideoInfoBadgeView.isHidden && !mediaDurationBadge.isHidden {
        // Regular video: duration + mute share a top-leading pill.
        if mediaVideoInfoBadgeView.superview !== mediaContainerView {
          mediaContainerView.addSubview(mediaVideoInfoBadgeView)
        }
        if mediaVideoAudioIconView.superview !== mediaVideoInfoBadgeView {
          mediaVideoInfoBadgeView.addSubview(mediaVideoAudioIconView)
        }
        mediaVideoInfoBadgeView.backgroundColor = UIColor(white: 0.0, alpha: 0.56)
        mediaVideoInfoBadgeView.layer.cornerRadius = 11.0
        mediaVideoInfoBadgeView.clipsToBounds = true
        mediaDurationBadge.textColor = .white
        mediaVideoAudioIconView.backgroundColor = .clear
        mediaVideoAudioIconView.layer.cornerRadius = 0
        mediaVideoAudioIconView.clipsToBounds = false
        mediaVideoAudioIconView.contentMode = .scaleAspectFit
        let badgeText = mediaDurationBadge.text ?? ""
        let badgeHeight: CGFloat = 22.0
        let badgeInsetX: CGFloat = 8.0
        let badgeInsetY: CGFloat = 8.0
        let audioIconSize: CGFloat = mediaVideoAudioIconView.isHidden ? 0.0 : 11.0
        let textWidth = measuredTextWidth(badgeText, font: mediaDurationBadge.font)
        let badgeWidth =
          8.0 + textWidth
          + (audioIconSize > 0.0 ? 7.0 + audioIconSize : 0.0) + 8.0
        mediaVideoInfoBadgeView.frame = CGRect(
          x: badgeInsetX,
          y: badgeInsetY,
          width: badgeWidth,
          height: badgeHeight
        )
        mediaVideoTimeIconView.frame = .zero
        let labelX: CGFloat = 8.0
        let trailingInset: CGFloat = mediaVideoAudioIconView.isHidden ? 8.0 : (8.0 + audioIconSize + 4.0)
        mediaDurationBadge.frame = CGRect(
          x: labelX,
          y: 0.0,
          width: max(1.0, badgeWidth - labelX - trailingInset),
          height: badgeHeight
        )
        if !mediaVideoAudioIconView.isHidden {
          mediaVideoAudioIconView.frame = CGRect(
            x: badgeWidth - audioIconSize - 8.0,
            y: floor((badgeHeight - audioIconSize) * 0.5),
            width: audioIconSize,
            height: audioIconSize
          )
        }
      }
      if !mediaTitleLabel.isHidden && row.visualKind == .sticker
        && isTransparentStickerMessage(row)
      {
        // Emoji fallback: center in full cell area
        mediaTitleLabel.frame = CGRect(
          x: 0,
          y: 0,
          width: width,
          height: height
        )
      } else if !mediaTitleLabel.isHidden
        && (row.visualKind == .media || row.visualKind == .sticker)
      {
        mediaTitleLabel.frame = CGRect(
          x: 8.0,
          y: height - 24.0,
          width: max(1.0, width - 16.0),
          height: 16.0
        )
      }

    case .text:
      break
    }

    let gridCount = chatMediaGridImageCount(row)
    if gridCount > 1 {
      // Full media canvas: the stack owns its own internal card geometry, and its
      // height came from `chatMediaStackHeight` in the sizing pass.
      mediaStackView?.frame = CGRect(x: 0, y: 0, width: width, height: height)
    } else {
      mediaStackView?.frame = .zero
    }

    // Documents place their own transfer affordance: the ring sits on the preview well —
    // where the tap target is — and the progress text rides the cell's second line
    // ("18 KB · Downloading 40%"), the way Telegram does it. The generic corner badge
    // below is sized for a photo: on a file row it lands on top of the filename, which is
    // the "Downloading" pill printed across "pdf" in the report.
    if !mediaProgressOverlayView.isHidden, row.visualKind == .document {
      mediaProgressSizeLabel.isHidden = true
      mediaProgressSizeLabel.frame = .zero
    } else if !mediaProgressOverlayView.isHidden {
      let ringSize: CGFloat = row.visualKind == .videoNote ? 48.0 : 52.0
      let labelHeight: CGFloat = mediaProgressSizeLabel.isHidden ? 0.0 : 20.0
      let labelGap: CGFloat = mediaProgressSizeLabel.isHidden ? 0.0 : 8.0
      mediaProgressOverlayView.frame = CGRect(x: 0, y: 0, width: width, height: height)
      let clusterHeight = ringSize + labelGap + labelHeight
      let clusterY = floor((height - clusterHeight) * 0.5)
      let ringX = floor((width - ringSize) * 0.5)
      mediaProgressRingView.frame = CGRect(
        x: ringX, y: clusterY, width: ringSize, height: ringSize)
      mediaProgressSpinner.isHidden = true
      if !mediaProgressSizeLabel.isHidden {
        let labelText = mediaProgressSizeLabel.text ?? ""
        let labelWidth = min(
          max(44.0, measuredTextWidth(labelText, font: mediaProgressSizeLabel.font) + 10.0),
          max(44.0, width - 16.0)
        )
        mediaProgressSizeLabel.frame = CGRect(
          x: floor((width - labelWidth) * 0.5),
          y: mediaProgressRingView.frame.maxY + labelGap,
          width: labelWidth,
          height: labelHeight
        )
      }
    }
    if !mediaPrimaryIconView.isHidden {
      mediaContainerView.bringSubviewToFront(mediaPrimaryIconView)
    }
  }

  @discardableResult
  private func configureStickerAnimation(for row: ChatListRow) -> Bool {
    guard row.visualKind == .sticker,
      let filePath = resolvedStickerAnimationFilePath(for: row)
    else {
      NSLog(
        "[ChatStickerCell] no Lottie path for msgId=%@ stickerId=%@ bundle=%@ packId=%@ mediaUrl=%@ text=%@",
        row.messageId ?? "-",
        row.stickerId ?? "-",
        row.stickerBundleFileName ?? "-",
        row.stickerPackId ?? "-",
        row.mediaUrl ?? "-",
        row.text
      )
      resetStickerAnimation()
      return false
    }

    NSLog("[ChatStickerCell] Lottie path=%@", filePath)

    // The one path that genuinely needs a Lottie view, so the one path that builds it.
    let stickerView = mediaStickerAnimationView
    if currentStickerAnimationKey != filePath || stickerView.animation == nil {
      stickerView.stop()
      stickerView.animation = LottieAnimation.filepath(filePath)
      currentStickerAnimationKey = filePath
    }

    let hasAnimation = stickerView.animation != nil
    stickerView.isHidden = !hasAnimation
    if !hasAnimation {
      NSLog("[ChatStickerCell] Lottie parse FAILED for path=%@", filePath)
      currentStickerAnimationKey = nil
    } else {
      NSLog("[ChatStickerCell] Lottie loaded OK, playing")
    }
    updateStickerAnimationPlayback()
    return hasAnimation
  }

  /// Runs on reuse for every cell, sticker or not — so it must clear a view that exists
  /// and do nothing at all for one that does not.
  private func resetStickerAnimation() {
    currentStickerAnimationKey = nil
    guard let stickerView = _mediaStickerAnimationView else { return }
    stickerView.stop()
    stickerView.animation = nil
    stickerView.isHidden = true
  }

  private func updateStickerAnimationPlayback() {
    // No view means no animation to start or stop.
    guard let mediaStickerAnimationView = _mediaStickerAnimationView else { return }
    let shouldPlay =
      window != nil
      && !mediaStickerAnimationView.isHidden
      && !mediaContainerView.isHidden
      && mediaContainerView.alpha > 0.01
      && !isContextMenuExtracted

    if shouldPlay {
      if !mediaStickerAnimationView.isAnimationPlaying {
        mediaStickerAnimationView.play()
      }
    } else if mediaStickerAnimationView.isAnimationPlaying {
      mediaStickerAnimationView.pause()
    }
  }

  @objc private func handleMediaProgressCancelTap() {
    guard let row else { return }
    if row.shouldShowUploadOverlay || mediaIsDownloading {
      onVoiceUploadCancelTap?(row)
    }
  }

  @objc private func handleInlineVideoMuteTap() {
    guard mediaVideoHasAudio else { return }
    mediaVideoIsMuted.toggle()
    mediaVideoPlayer?.isMuted = mediaVideoIsMuted
    // An unmute is explicit audio intent, so later refreshes may keep the session set.
    mediaVideoUserInitiatedPlay = true
    configureInlineVideoAudioSession(muted: mediaVideoIsMuted)
    updateInlineVideoAudioIcon()
  }

  /// Loads album cover onto the compact music play plate (warm cache → network).
  private func loadMusicCoverArtwork(for row: ChatListRow) {
    let warm = chatMusicArtworkImage(for: row)
    // A nil cover is "not resolved yet", never "clear the plate".
    if let warm { mediaVoiceButtonView.setArtworkImage(warm) }
    clearMediaImageIfNoBetterPixels()
    if warm == nil { recoverArtworkFromAudioFile(for: row) }
    guard let raw = row.musicCoverURL?.trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty,
      chatMediaImageCache.object(forKey: chatMusicCoverCacheKey(raw) as NSString) == nil
    else { return }
    let rowKey = row.messageId ?? row.key
    let coverURL = row.musicCoverURL
    musicCoverTask?.cancel()
    musicCoverTask = chatLoadMusicCover(urlString: raw) { [weak self] image in
      guard let self, let current = self.row,
        (current.messageId ?? current.key) == rowKey,
        current.musicCoverURL == coverURL
      else { return }
      self.mediaVoiceButtonView.setArtworkImage(image)
      self.clearMediaImageIfNoBetterPixels()
    }
  }

  /// No cover anywhere — read the track's own tags off whichever copy of the audio this device
  /// has (the sender's local file, or the durable vault copy a download/upload seed left).
  private func recoverArtworkFromAudioFile(for row: ChatListRow) {
    guard usesAudioMetadataVoiceLayout(row) else { return }
    guard let messageId = row.messageId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !messageId.isEmpty
    else { return }
    let audioURL: URL? = {
      if let local = chatExistingLocalMediaPath(row.localMediaUrl) {
        return URL(fileURLWithPath: local)
      }
      guard let raw = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
        let remoteURL = URL(string: raw), !remoteURL.isFileURL
      else { return nil }
      return VoiceBubblePlaybackCoordinator.shared.resolvedCachedLocalURL(
        forRemote: remoteURL, fileName: row.fileName)
    }()
    guard let audioURL else { return }
    chatRecoveredAudioTags.recover(messageId: messageId, fileURL: audioURL) { [weak self] tags in
      guard let self, let current = self.row,
        current.messageId?.trimmingCharacters(in: .whitespacesAndNewlines) == messageId,
        let artwork = tags.artwork
      else { return }
      self.mediaVoiceButtonView.setArtworkImage(artwork)
      self.clearMediaImageIfNoBetterPixels()
    }
  }

  /// The chat id that owns this row: the per-message `chat_id` when present, else the list's
  /// stamped `hostChatId`. Music messages usually lack an embedded `chat_id`, so without this
  /// the tapped track carries no chat id and the player sheet can't list the chat's other music.
  private func effectiveHostChatId(for row: ChatListRow) -> String? {
    if let rowChatId = row.chatId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !rowChatId.isEmpty
    {
      return rowChatId
    }
    let trimmedHost = hostChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedHost.isEmpty ? nil : trimmedHost
  }

  @objc private func handleVoiceTap() {
    guard let row, row.visualKind == .voice else { return }
    if row.shouldShowUploadOverlay {
      onVoiceUploadCancelTap?(row)
      return
    }
    VoiceBubblePlaybackCoordinator.shared.toggle(
      cell: self,
      messageId: row.messageId,
      chatId: effectiveHostChatId(for: row),
      mediaURL: resolvedVoicePlaybackURL(for: row),
      mediaKey: row.mediaKey,
      fileName: row.fileName,
      title: usesAudioMetadataVoiceLayout(row) ? resolvedAudioVoiceTitle(row) : nil,
      subtitle: usesAudioMetadataVoiceLayout(row) ? resolvedAudioVoiceStaticDetail(row) : nil,
      artwork: usesAudioMetadataVoiceLayout(row) ? chatMusicArtworkImage(for: row) : nil,
      duration: row.duration,
      presentsGlobalPlayer: usesAudioMetadataVoiceLayout(row)
    )
  }

  @objc private func handleRetryTap() {
    guard let row else { return }
    onRetryMessageTap?(row)
  }

  @objc private func handleNotSentTap() {
    guard let row else { return }
    onNotSentTap?(row)
  }

  @objc private func handleAgentErrorNoticeTap() {
    // The day pill is shared with real day/interrupt dividers, which must stay inert.
    guard isConfiguredAgentErrorNotice, let row else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    onAgentErrorRetryTap?(row)
  }

  /// Builds the centered agent-error pill text: a small warning glyph, the calm message,
  /// and an accent "Try again" affordance, all on one line inside the day pill.
  private func agentErrorNoticeAttributedText(message: String) -> NSAttributedString {
    let font = UIFont.systemFont(ofSize: 12, weight: .semibold)
    let messageColor = appearance.dayTextColor
    let actionColor = appearance.accent
    let result = NSMutableAttributedString()

    if let glyph = UIImage(
      systemName: "exclamationmark.triangle.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 11.0, weight: .semibold))?
      .withTintColor(.systemOrange, renderingMode: .alwaysOriginal)
    {
      let attachment = NSTextAttachment()
      attachment.image = glyph
      let dy = (font.capHeight - glyph.size.height) / 2.0
      attachment.bounds = CGRect(x: 0, y: dy, width: glyph.size.width, height: glyph.size.height)
      result.append(NSAttributedString(attachment: attachment))
      result.append(NSAttributedString(string: "  "))
    }

    result.append(
      NSAttributedString(
        string: message,
        attributes: [.font: font, .foregroundColor: messageColor]))
    result.append(
      NSAttributedString(
        string: "   ",
        attributes: [.font: font, .foregroundColor: messageColor]))
    result.append(
      NSAttributedString(
        string: "Try again",
        attributes: [.font: font, .foregroundColor: actionColor]))
    return result
  }

  @objc private func handleAgentRegenerateTap() {
    guard let row else { return }
    let sourceMessageId = row.agentActionSourceId ?? ""
    guard !sourceMessageId.isEmpty else { return }
    onAgentAction?([
      "type": "agentMessageAction",
      "action": "regenerate",
      "sourceMessageId": sourceMessageId,
      "sourceText": row.agentActionSourceText ?? row.plainContent ?? row.text,
      "regeneratePrompt": row.agentRegeneratePrompt ?? "",
    ])
  }

  @objc private func handleViewAgentTap() {
    guard let row, let messageId = row.messageId, !messageId.isEmpty else { return }
    onAgentAction?([
      "type": "viewAgent",
      "messageId": messageId,
      "chatId": row.chatId ?? "",
    ])
  }

  /// A per-task working tint for an in-flight agent bubble, or nil once the turn is
  /// finished/errored (so the bubble settles back to the default chat accent). Seeded
  /// from a stable id so one run keeps a single color across its live updates, but kept
  /// inside the wallpaper's blue-violet family so it does not fight the chat palette.
  static func agentWorkingAccent(for row: ChatListRow) -> UIColor? {
    guard row.isAgentMessage, row.isStreamingText, !row.isAgentError else { return nil }
    let seed = row.agentActionSourceId ?? row.messageId ?? row.key
    var hash: UInt64 = 1_469_598_103_934_665_603
    for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
    let hue = (224.0 + CGFloat(hash % 54)) / 360.0
    return UIColor(hue: hue, saturation: 0.44, brightness: 0.88, alpha: 1.0)
  }

  /// The old outside-bubble "view agent" arrow is intentionally retired. Active
  /// agent progress rows expose the push control inside the bubble preview.
  private func showsAgentView(_ row: ChatListRow) -> Bool {
    _ = row
    return false
  }

  /// Agent message that offers regenerate. Now scoped to *errored* responses
  /// only (a failed turn the user can retry) — successful answers no longer
  /// carry the side button. Drives both the side button and long-press menu.
  private func showsAgentRegenerate(_ row: ChatListRow) -> Bool {
    row.kind == .message
      && row.isAgentMessage
      && row.isAgentError
      && !row.isStreamingText
      && (row.agentActionSourceId?.isEmpty == false)
      && (row.agentRegeneratePrompt?.isEmpty == false)
  }

  @objc private func handleSelectionToggle() {
    guard let row else { return }
    onSelectionToggle?(row)
  }

  @objc private func handleInlineAttachmentTap() {
    guard let row, hasInlineAttachment(row) else { return }
    onInlineAttachmentTap?(row)
  }

  func hitTestInlineAttachment(at pointInCell: CGPoint) -> Bool {
    guard let row, hasInlineAttachment(row), !inlineAttachmentView.isHidden else {
      return false
    }
    let local = contentView.convert(pointInCell, from: self)
    return inlineAttachmentView.frame.contains(local)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    lastTouchPointInCell = touches.first?.location(in: self)
    lastTouchAt = ProcessInfo.processInfo.systemUptime
    super.touchesBegan(touches, with: event)
  }

  /// Whether the last touch landed on the media itself rather than anywhere in the row.
  /// No recent point means open — an interactive subview can swallow the touch, and a
  /// dead media tap is worse than an over-broad one.
  func lastTouchWasOnMediaContent() -> Bool {
    guard let point = lastTouchPointInCell,
      ProcessInfo.processInfo.systemUptime - lastTouchAt < 2.0
    else { return true }
    var regions: [UIView] = [mediaContainerView, inlineAttachmentView]
    if let stack = mediaStackView { regions.append(stack) }
    if let preview = _linkPreviewView { regions.append(preview) }
    for region in regions where !region.isHidden && region.superview != nil {
      if region.convert(region.bounds, to: self).contains(point) { return true }
    }
    return false
  }

  func applyVoicePlaybackState(isPlaying: Bool, progress: CGFloat, level: CGFloat) {
    if let row, row.shouldShowUploadOverlay {
      let uploadProgress: CGFloat?
      if let value = row.uploadProgress, value.isFinite {
        uploadProgress = CGFloat(max(0.0, min(1.0, value)))
      } else {
        uploadProgress = nil
      }
      mediaVoiceButtonView.setUploadState(isUploading: true, progress: uploadProgress)
      mediaWaveformView.setPlayback(
        progress: uploadProgress ?? 0.0,
        level: 0.0,
        isPlaying: false
      )
      refreshVoiceMetadataText()
      return
    }
    mediaVoiceButtonView.setUploadState(isUploading: false, progress: nil)
    mediaVoiceButtonView.setPlaybackState(isPlaying: isPlaying, progress: progress, level: level)
    mediaWaveformView.setPlayback(progress: progress, level: level, isPlaying: isPlaying)
    refreshVoiceMetadataText()
  }

  func applyVoiceDownloadState(needsDownload: Bool, isDownloading: Bool, progress: CGFloat?) {
    let downloadChromeChanged = mediaIsDownloading != isDownloading
    mediaNeedsDownload = needsDownload
    mediaIsDownloading = isDownloading
    // Any fresh state push (idle / loading / playing) supersedes a latched failure.
    mediaDownloadFailed = false
    mediaDownloadProgress = progress.map(Double.init)
    // Live byte counts from the coordinator (same source the snapshot publishes for the sheet).
    if isDownloading {
      let counts = VoiceBubblePlaybackCoordinator.shared.activeDownloadByteCounts
      mediaDownloadedBytes = counts.downloaded
      mediaTotalDownloadBytes = counts.total
    } else {
      mediaDownloadedBytes = nil
      mediaTotalDownloadBytes = nil
    }
    guard !(row?.shouldShowUploadOverlay == true) else { return }
    mediaVoiceButtonView.setDownloadState(
      needsDownload: needsDownload,
      isDownloading: isDownloading,
      progress: progress
    )
    if needsDownload {
      mediaWaveformView.setPlayback(progress: progress ?? 0.0, level: 0.0, isPlaying: false)
    }
    refreshVoiceMetadataText()
    if downloadChromeChanged {
      setNeedsLayout()
    }
  }

  func applyVoiceDownloadFailedState() {
    mediaDownloadFailed = true
    mediaNeedsDownload = true
    mediaIsDownloading = false
    mediaDownloadProgress = nil
    mediaDownloadedBytes = nil
    mediaTotalDownloadBytes = nil
    guard !(row?.shouldShowUploadOverlay == true) else { return }
    mediaVoiceButtonView.setDownloadFailed()
    mediaWaveformView.setPlayback(progress: 0.0, level: 0.0, isPlaying: false)
    refreshVoiceMetadataText()
    setNeedsLayout()
  }

  func applyMediaDownloadState(needsDownload: Bool, isDownloading: Bool, progress: Double?) {
    mediaNeedsDownload = needsDownload
    mediaIsDownloading = isDownloading
    mediaDownloadProgress = progress
    if !isDownloading {
      mediaDownloadedBytes = nil
      mediaTotalDownloadBytes = nil
    }
    guard let row, !(row.shouldShowUploadOverlay) else { return }
    updateMediaTransferChrome(for: row)
    refreshInlineVideoPlaybackIfNeeded()
    updateMediaPlaceholderVisibility()
    refreshVoiceMetadataText()
    setNeedsLayout()
  }

  /// `animated` is for the page that was just RENDERED — a cross-fade from the placeholder
  /// plate to real pixels. A cached page must arrive without one: `configure` re-applies
  /// the same image on every reuse, so fading there made each document fade in again on
  /// every chat open and every scroll pass — the reported flickering opacity.
  func applyDocumentPreview(
    _ image: UIImage, pageCount: Int, messageId: String?, animated: Bool
  ) {
    guard let row, row.visualKind == .document,
      (row.messageId ?? row.key) == (messageId ?? row.key)
    else {
      return
    }
    documentPageCount = pageCount > 0 ? pageCount : nil
    mediaPixelQuality = .full
    refreshDocumentDetail()
    let apply = {
      self.mediaImageView.image = image
      self.mediaImageView.isHidden = false
      self.mediaPrimaryIconView.isHidden = true
      self.setMediaPlaceholderHidden(true)
    }
    // Already showing exactly these pixels: nothing to fade, nothing to re-apply.
    if mediaImageView.image === image, !mediaImageView.isHidden {
      return
    }
    if animated, window != nil {
      UIView.transition(
        with: mediaImageView,
        duration: 0.22,
        options: [.transitionCrossDissolve, .beginFromCurrentState, .allowAnimatedContent],
        animations: apply
      )
    } else {
      apply()
    }
  }

  /// اندازهٔ فایل که با HEAD کشف شده؛ سرور برای پیوست‌های بیرونی طولی نمی‌فرستد.
  func applyDocumentByteSize(_ bytes: Int64, messageId: String?) {
    guard let row, row.visualKind == .document,
      (row.messageId ?? row.key) == (messageId ?? row.key), bytes > 0
    else {
      return
    }
    documentByteSize = bytes
    refreshDocumentDetail()
  }

  private func refreshDocumentDetail() {
    guard let row, row.visualKind == .document else { return }
    let color = row.isMe ? appearance.textColorMe : appearance.textColorThem
    mediaDetailLabel.attributedText = documentDetailAttributedText(
      for: row, baseColor: color, accent: appearance.accent)
  }

  private func documentPlateColor(for row: ChatListRow, appearance: ChatListAppearance) -> UIColor {
    // رنگِ بی‌طرف، نه رنگِ تأکید: نشان نباید با دکمهٔ دانلود اشتباه گرفته شود.
    appearance.isDark
      ? UIColor(white: 1.0, alpha: 0.16)
      : UIColor(white: 0.0, alpha: 0.20)
  }

  private func documentByteSizeValue(for row: ChatListRow) -> Int64? {
    if let bytes = row.fileSize, bytes > 0 { return bytes }
    if let documentByteSize, documentByteSize > 0 { return documentByteSize }
    if let total = mediaTotalDownloadBytes, total > 0 { return total }
    return nil
  }

  /// «۲۰٫۹ KB» یا هنگام نبودِ نسخهٔ محلی «۲۰٫۹ KB · Download» با واژهٔ رنگی —
  /// همان قراردادی که تلگرام دارد و کاربر انتظارش را دارد.
  private func documentDetailAttributedText(
    for row: ChatListRow, baseColor: UIColor, accent: UIColor
  ) -> NSAttributedString {
    let font = UIFont.systemFont(ofSize: 13, weight: .regular)
    var lead: [String] = []
    if let bytes = documentByteSizeValue(for: row) {
      lead.append(formatDownloadByteCount(bytes))
    }
    if let documentPageCount, documentPageCount > 0 {
      lead.append(documentPageCount == 1 ? "1 page" : "\(documentPageCount) pages")
    }
    // The type label is a FALLBACK for the second line, not a caption for the first: when
    // the name is itself a type label (no real filename arrived — "Web Page", "PDF
    // Document"), repeating it below prints the same words twice in one cell.
    if lead.isEmpty, chatDocumentDisplayName(row) != chatDocumentTypeLabel(row) {
      lead.append(chatDocumentTypeLabel(row))
    }

    if mediaIsDownloading {
      // `lead` can legitimately be empty now, so the leading fact is optional — indexing
      // it would trap.
      let prefix = lead.first.map { "\($0) · " } ?? ""
      let percent = Int(((mediaDownloadProgress ?? 0.0) * 100.0).rounded())
      let text = percent > 0 ? "\(prefix)Downloading \(percent)%" : "\(prefix)Downloading"
      return NSAttributedString(
        string: text,
        attributes: [.font: font, .foregroundColor: baseColor.withAlphaComponent(0.62)])
    }

    let result = NSMutableAttributedString(
      string: lead.joined(separator: " · "),
      attributes: [.font: font, .foregroundColor: baseColor.withAlphaComponent(0.62)])

    if mediaNeedsDownload {
      if result.length > 0 {
        result.append(
          NSAttributedString(
            string: " · ",
            attributes: [.font: font, .foregroundColor: baseColor.withAlphaComponent(0.62)]))
      }
      result.append(
        NSAttributedString(
          string: "Download",
          attributes: [
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: accent,
          ]))
    }
    return result
  }

  func setExternalVoicePlayback(messageId: String?, isPlaying: Bool, progress: CGFloat) {
    externalVoiceMessageId = messageId
    externalVoiceIsPlaying = isPlaying
    externalVoiceProgress = max(0.0, min(1.0, progress))
    applyExternalVoicePlaybackIfNeeded()
  }

  private func applyExternalVoicePlaybackIfNeeded() {
    guard let row, row.visualKind == .voice else { return }
    // While the sender still has the local file (right after upload, before the
    // server echo strips localMediaUrl), cache it under the remote URL so the
    // bubble shows play instead of a download button for our own sent media.
    VoiceBubblePlaybackCoordinator.shared.seedRemoteVoiceCacheFromLocal(
      localMediaURL: row.localMediaUrl,
      remoteMediaURL: row.mediaUrl,
      fileName: row.fileName
    )
    let rowId = row.messageId ?? ""
    let externalId = externalVoiceMessageId ?? ""
    guard !rowId.isEmpty else {
      VoiceBubblePlaybackCoordinator.shared.bind(
        cell: self,
        messageId: nil,
        mediaURL: resolvedVoicePlaybackURL(for: row),
        mediaKey: row.mediaKey,
        fileName: row.fileName
      )
      applyVoicePlaybackState(isPlaying: false, progress: 0.0, level: 0.0)
      return
    }
    if rowId == externalId {
      applyVoiceDownloadState(needsDownload: false, isDownloading: false, progress: nil)
      applyVoicePlaybackState(
        isPlaying: externalVoiceIsPlaying,
        progress: externalVoiceProgress,
        level: externalVoiceIsPlaying ? 0.20 : 0.0
      )
    } else {
      VoiceBubblePlaybackCoordinator.shared.bind(
        cell: self,
        messageId: row.messageId,
        mediaURL: resolvedVoicePlaybackURL(for: row),
        mediaKey: row.mediaKey,
        fileName: row.fileName
      )
    }
  }

  private func layoutMetaLabels(for row: ChatListRow) {
    let widths = bubbleMetaWidths(for: row)
    let usesViewOnceMetaPlate =
      row.viewOnce && usesFullBleedMediaLayout(row) && row.visualKind != .videoNote
    let metaInsetX: CGFloat = usesViewOnceMetaPlate ? 6.0 : 0.0
    let metaInsetY: CGFloat = usesViewOnceMetaPlate ? 2.0 : 0.0
    var cursorX = metaInsetX
    let baselineY = metaInsetY + max(0.0, floor((bubbleMetaHeight - 12.0) * 0.5))

    func hide(_ label: UILabel) {
      label.isHidden = true
      label.frame = .zero
    }

    func place(_ label: UILabel, width: CGFloat, height: CGFloat = 12.0, centered: Bool = false) {
      label.isHidden = false
      let y =
        centered ? metaInsetY + floor((bubbleMetaHeight - height) * 0.5) : baselineY
      label.frame = CGRect(x: cursorX, y: y, width: width, height: height)
      cursorX += width + bubbleMetaItemGap
    }

    if widths.views > 0.0 {
      viewIconView.isHidden = false
      viewCountLabel.isHidden = false
      viewIconView.frame = CGRect(x: cursorX, y: baselineY + 1.0, width: 12.0, height: 10.0)
      let countWidth = max(0.0, widths.views - 14.0)
      viewCountLabel.frame = CGRect(
        x: viewIconView.frame.maxX + 2.0, y: baselineY, width: countWidth, height: 12.0)
      cursorX += widths.views + bubbleMetaItemGap
    } else {
      viewIconView.isHidden = true
      viewIconView.frame = .zero
      hide(viewCountLabel)
    }

    if row.isEdited {
      place(editedLabel, width: widths.edited)
    } else {
      hide(editedLabel)
    }

    if row.isPinned {
      place(pinnedLabel, width: widths.pinned)
    } else {
      hide(pinnedLabel)
    }

    place(timestampLabel, width: widths.timestamp)
    let statusY =
      metaInsetY + floor((bubbleMetaHeight - bubbleStatusSlotHeight) * 0.5)
    let statusFrame = pixelAlignedRect(
      CGRect(
        x: cursorX,
        y: statusY,
        width: bubbleStatusSlotWidth,
        height: bubbleStatusSlotHeight
      ))
    statusLabel.frame = statusFrame
    statusImageView.frame = statusFrame
    pendingStatusView.frame = statusFrame
  }

  private func configureStatus(for newRow: ChatListRow, baseColor: UIColor) {
    let newStatus = (resolveDisplayStatus?(newRow) ?? newRow.status)?.lowercased()
    let oldStatusKey = renderedStatusKey
    let nextStatusKey = newRow.isMe ? (newStatus ?? "none") : nil

    statusLabel.text = nil
    statusLabel.textColor = baseColor
    statusLabel.font = bubbleMetaStatusFont
    statusLabel.isHidden = true
    statusImageView.image = nil
    statusImageView.isHidden = true
    statusImageView.layer.opacity = 1.0
    pendingStatusView.isHidden = true
    pendingStatusView.stopAnimating()

    guard newRow.isMe else {
      renderedStatusKey = nil
      renderedStatusGlyph = nil
      retryButton.isHidden = true
      return
    }

    // One tick means the message reached the service; two ticks mean the recipient
    // actually read it. `delivered` used to draw the double tick too, which made
    // "arrived on their device" and "they read it" indistinguishable — the only two
    // states this indicator exists to separate.
    var nextGlyph: String? = nil
    switch newStatus {
    case "pending", "sending":
      pendingStatusView.configure(color: baseColor)
      pendingStatusView.isHidden = false
      nextGlyph = "pending"
    case "sent", "delivered":
      statusImageView.image = bubbleStatusCheckImage(
        double: false, color: bubbleStatusTickColor(base: baseColor, read: false))
      statusImageView.isHidden = false
      nextGlyph = "single"
    case "read":
      statusImageView.image = bubbleStatusCheckImage(
        double: true, color: bubbleStatusTickColor(base: baseColor, read: true))
      statusImageView.isHidden = false
      nextGlyph = "double"
    case "error":
      statusLabel.text = "!"
      statusLabel.textColor = UIColor(red: 1.0, green: 0.48, blue: 0.48, alpha: 1.0)
      statusLabel.isHidden = false
      nextGlyph = "error"
    default:
      break
    }

    // No second affordance. A failed outgoing message is marked by `notSentIndicator` —
    // the red "!" in the margin that every messaging app uses and that this transcript
    // already drew for `isDeliveryFailed` — and tapping that mark is what offers to send
    // it again. The extra arrow button beside it said the same thing twice, in a louder
    // voice, in the same six points of margin.
    retryButton.isHidden = true

    // Animate on the glyph the user can actually see changing, not on the raw status.
    // sent → delivered now draws the identical single tick, and popping it again there
    // would be a flicker with no meaning behind it.
    let oldGlyph = renderedStatusGlyph
    let shouldAnimateCheckIn =
      oldStatusKey != nil
      && oldGlyph != nextGlyph
      && statusImageView.isHidden == false
      && (nextGlyph == "single" || nextGlyph == "double")
    let shouldAnimateError =
      oldStatusKey != nil
      && oldStatusKey != nextStatusKey
      && newStatus == "error"
    renderedStatusKey = nextStatusKey
    renderedStatusGlyph = nextGlyph
    if shouldAnimateCheckIn {
      animateStatusGlyphIn()
    }
    if shouldAnimateError {
      animateBubbleErrorNudge()
    }
  }

  /// Delivery ticks take the bubble's own meta color, which is already resolved against
  /// the active theme/appearance (`resolvedMetaColor`), so they stay legible on a dark
  /// bubble, a light bubble, and any configured palette. They were hard-coded white,
  /// which disappeared entirely on light outgoing bubbles. Read draws the same color at
  /// full strength: the tick COUNT carries the state, the extra weight makes the change
  /// readable at a glance without introducing a color the theme never chose.
  private func bubbleStatusTickColor(base: UIColor, read: Bool) -> UIColor {
    guard read else { return base }
    var white: CGFloat = 0.0
    var alpha: CGFloat = 0.0
    if base.getWhite(&white, alpha: &alpha) {
      return UIColor(white: white, alpha: min(1.0, alpha + 0.35))
    }
    var red: CGFloat = 0.0
    var green: CGFloat = 0.0
    var blue: CGFloat = 0.0
    if base.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
      return UIColor(red: red, green: green, blue: blue, alpha: min(1.0, alpha + 0.35))
    }
    return base
  }

  private func animateBubbleErrorNudge() {
    bubbleView.layer.removeAnimation(forKey: "bubbleErrorNudge")
    let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
    animation.values = [0.0, -4.0, 3.0, -2.0, 0.0]
    animation.keyTimes = [0.0, 0.24, 0.52, 0.76, 1.0]
    animation.duration = 0.28
    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    animation.isRemovedOnCompletion = true
    bubbleView.layer.add(animation, forKey: "bubbleErrorNudge")
  }

  private func animateStatusGlyphIn() {
    statusImageView.layer.removeAnimation(forKey: "statusCheckScaleIn")
    statusImageView.layer.removeAnimation(forKey: "statusCheckFadeIn")
    statusImageView.layer.opacity = 1.0

    let scale = CASpringAnimation(keyPath: "transform.scale")
    scale.fromValue = 0.82
    scale.toValue = 1.0
    scale.mass = 0.7
    scale.stiffness = 520.0
    scale.damping = 34.0
    scale.initialVelocity = 0.0
    scale.duration = 0.2
    scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
    scale.isRemovedOnCompletion = true

    statusImageView.layer.add(scale, forKey: "statusCheckScaleIn")
  }

  func setContextMenuExtracted(_ extracted: Bool) {
    isContextMenuExtracted = extracted
    holdDebugLog("setExtracted extracted=\(extracted)")
    applyContextMenuExtractionIfNeeded()
  }

  func setContextMenuHeld(_ held: Bool, animated: Bool, strategy: String = "scaleCell") {
    if isContextMenuHeld == held {
      let alreadyIdentity = transform.isIdentity && contentView.transform.isIdentity
      if held || alreadyIdentity {
        holdDebugLog("setHeld skip held=\(held) animated=\(animated) strategy=\(strategy)")
        return
      }
    }
    isContextMenuHeld = held
    holdDebugLog("setHeld held=\(held) animated=\(animated) strategy=\(strategy)")
    applyContextMenuHoldIfNeeded(animated: animated, strategy: strategy)
  }

  private func holdDebugLog(_ message: String) {
    guard chatCellHoldDebugLogs else { return }
    NSLog("[ChatCellHold] %@", message)
  }

  private func reactionDebugLog(_ message: String) {
    guard chatCellReactionDebugLogs else { return }
    NSLog("[ChatCellReaction] %@", message)
  }

  private func applyContextMenuExtractionIfNeeded() {
    if isContextMenuExtracted {
      if !hasSavedExtractionState {
        savedBubbleHiddenBeforeExtraction = bubbleView.isHidden
        savedTailHiddenBeforeExtraction = tailView.isHidden
        savedReactionHiddenBeforeExtraction = reactionStripView.isHidden
        savedMessageAlphaBeforeExtraction = messageLabel.alpha
        savedAgentTurnContentAlphaBeforeExtraction = _agentTurnContentView?.alpha ?? 1.0
        savedRichTextAlphaBeforeExtraction = richTextView.alpha
        savedReplyPreviewAlphaBeforeExtraction = replyPreviewView.alpha
        savedLinkPreviewAlphaBeforeExtraction = _linkPreviewView?.alpha ?? 1.0
        savedInlineAttachmentAlphaBeforeExtraction = inlineAttachmentView.alpha
        savedMediaAlphaBeforeExtraction = mediaContainerView.alpha
        savedMetaAlphaBeforeExtraction = metaContainerView.alpha
        hasSavedExtractionState = true
      }
      bubbleView.isHidden = true
      tailView.isHidden = true
      reactionStripView.isHidden = true
      // Keep text/media/meta rendering alive for snapshot correctness, but hide them.
      messageLabel.alpha = 0.0
      _agentTurnContentView?.alpha = 0.0
      richTextView.alpha = 0.0
      replyPreviewView.alpha = 0.0
      _linkPreviewView?.alpha = 0.0
      inlineAttachmentView.alpha = 0.0
      mediaContainerView.alpha = 0.0
      metaContainerView.alpha = 0.0
      updateStickerAnimationPlayback()
      holdDebugLog("applyExtraction extracted=true hidden=true")
      return
    }

    guard hasSavedExtractionState else { return }
    bubbleView.isHidden = savedBubbleHiddenBeforeExtraction
    tailView.isHidden = savedTailHiddenBeforeExtraction
    reactionStripView.isHidden = savedReactionHiddenBeforeExtraction
    messageLabel.alpha = savedMessageAlphaBeforeExtraction
    _agentTurnContentView?.alpha = savedAgentTurnContentAlphaBeforeExtraction
    richTextView.alpha = savedRichTextAlphaBeforeExtraction
    replyPreviewView.alpha = savedReplyPreviewAlphaBeforeExtraction
    _linkPreviewView?.alpha = savedLinkPreviewAlphaBeforeExtraction
    inlineAttachmentView.alpha = savedInlineAttachmentAlphaBeforeExtraction
    mediaContainerView.alpha = savedMediaAlphaBeforeExtraction
    metaContainerView.alpha = savedMetaAlphaBeforeExtraction
    hasSavedExtractionState = false
    updateStickerAnimationPlayback()
    holdDebugLog("applyExtraction extracted=false restored=true")
  }

  // MARK: - Hold effect

  private func setAnchorPoint(_ anchorPoint: CGPoint, for view: UIView) {
    let oldOrigin = view.frame.origin
    view.layer.anchorPoint = anchorPoint
    let newOrigin = view.frame.origin
    let transition = CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y)
    view.center = CGPoint(x: view.center.x - transition.x, y: view.center.y - transition.y)
  }

  private func applyContentViewHoldAnchorIfNeeded() {
    guard contentView.bounds.width > 0, contentView.bounds.height > 0 else { return }

    // Pivot hold-scale around the bubble center (not the full row center)
    // so right/left aligned bubbles do not drift on X during press/release.
    let bubbleCenter = bubbleView.center
    let anchorX = max(0.0, min(1.0, bubbleCenter.x / contentView.bounds.width))
    let anchorY = max(0.0, min(1.0, bubbleCenter.y / contentView.bounds.height))
    setAnchorPoint(CGPoint(x: anchorX, y: anchorY), for: contentView)
    contentViewHoldAnchorApplied = true
  }

  private func applyCellHoldAnchorIfNeeded() {
    guard bounds.width > 0, bounds.height > 0 else { return }

    let bubbleCenter = contentView.convert(bubbleView.center, to: self)
    let anchorX = max(0.0, min(1.0, bubbleCenter.x / bounds.width))
    let anchorY = max(0.0, min(1.0, bubbleCenter.y / bounds.height))
    setAnchorPoint(CGPoint(x: anchorX, y: anchorY), for: self)
    cellHoldAnchorApplied = true
  }

  private func resetCellHoldAnchorIfNeeded() {
    guard cellHoldAnchorApplied else { return }
    setAnchorPoint(CGPoint(x: 0.5, y: 0.5), for: self)
    cellHoldAnchorApplied = false
  }

  private func resetContentViewHoldAnchorIfNeeded() {
    guard contentViewHoldAnchorApplied else { return }
    setAnchorPoint(CGPoint(x: 0.5, y: 0.5), for: contentView)
    contentViewHoldAnchorApplied = false
  }

  private func applyContextMenuHoldIfNeeded(animated: Bool, strategy: String) {
    let scale: CGFloat =
      strategy == "scaleCell"
      ? (isContextMenuHeld ? 0.95 : 1.0)
      : (isContextMenuHeld ? 0.95 : 1.0)
    var targetTransform: CGAffineTransform = .identity
    var cellTransform: CGAffineTransform = .identity

    if isContextMenuHeld {
      if strategy == "scaleCell" {
        applyCellHoldAnchorIfNeeded()
        cellTransform = CGAffineTransform(scaleX: scale, y: scale)
      } else {
        applyContentViewHoldAnchorIfNeeded()
        targetTransform = CGAffineTransform(scaleX: scale, y: scale)
      }
    } else {
      if strategy == "scaleCell" {
        cellTransform = .identity
      } else {
        targetTransform = .identity
      }
    }

    if strategy == "scaleCell" {
      resetContentViewHoldAnchorIfNeeded()
    }

    let applyChanges = {
      if strategy == "scaleCell" {
        self.transform = cellTransform
        self.contentView.transform = .identity
      } else {
        self.transform = .identity
        self.contentView.transform = targetTransform
      }
    }

    holdDebugLog(
      "applyHold begin held=\(isContextMenuHeld) animated=\(animated) strategy=\(strategy) scale=\(String(format: "%.3f", scale)) cell=\(NSCoder.string(for: self.transform)) content=\(NSCoder.string(for: self.contentView.transform))"
    )

    if !animated {
      applyChanges()
      holdDebugLog(
        "applyHold end(noanim) held=\(isContextMenuHeld) strategy=\(strategy) cell=\(NSCoder.string(for: self.transform)) content=\(NSCoder.string(for: self.contentView.transform))"
      )
      if !isContextMenuHeld {
        if strategy == "scaleCell" {
          resetCellHoldAnchorIfNeeded()
        } else {
          resetContentViewHoldAnchorIfNeeded()
        }
      }
      return
    }

    if strategy == "scaleCell" {
      let completion: (Bool) -> Void = { _ in
        self.holdDebugLog(
          "applyHold end(anim) held=\(self.isContextMenuHeld) strategy=\(strategy) cell=\(NSCoder.string(for: self.transform)) content=\(NSCoder.string(for: self.contentView.transform))"
        )
        if !self.isContextMenuHeld {
          self.resetCellHoldAnchorIfNeeded()
        }
      }
      if isContextMenuHeld {
        // Slow real-time sink (matches the home-card hold): easeIn keeps the
        // first beats visually silent so the press reads as a gradual grab,
        // never a pop to a settled scale.
        UIView.animate(
          withDuration: 0.28,
          delay: 0,
          options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseIn],
          animations: {
            applyChanges()
          },
          completion: completion
        )
      } else {
        UIView.animate(
          withDuration: 0.24,
          delay: 0,
          usingSpringWithDamping: 0.90,
          initialSpringVelocity: 0,
          options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
          animations: {
            applyChanges()
          },
          completion: completion
        )
      }
      return
    }

    // A smooth, firm press using a modern UIView spring animation
    UIView.animate(
      withDuration: isContextMenuHeld ? 0.28 : 0.45,
      delay: 0,
      usingSpringWithDamping: isContextMenuHeld ? 0.95 : 0.65,
      initialSpringVelocity: 0,
      options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
    ) {
      applyChanges()
    } completion: { _ in
      self.holdDebugLog(
        "applyHold end(anim) held=\(self.isContextMenuHeld) strategy=\(strategy) cell=\(NSCoder.string(for: self.transform)) content=\(NSCoder.string(for: self.contentView.transform))"
      )
      if !self.isContextMenuHeld {
        if strategy == "scaleCell" {
          self.resetCellHoldAnchorIfNeeded()
        } else {
          self.resetContentViewHoldAnchorIfNeeded()
        }
      }
    }
  }

  private func resolvedMetaColor(for textColor: UIColor) -> UIColor {
    var r: CGFloat = 0.0
    var g: CGFloat = 0.0
    var b: CGFloat = 0.0
    var a: CGFloat = 0.0
    guard textColor.getRed(&r, green: &g, blue: &b, alpha: &a) else {
      return UIColor(white: 1.0, alpha: 0.65)
    }
    let luminance = (0.299 * r) + (0.587 * g) + (0.114 * b)
    if luminance > 0.8 {
      return UIColor(white: 1.0, alpha: 0.65)
    }
    return UIColor(white: 0.0, alpha: 0.55)
  }

  func bubbleRect(in view: UIView) -> CGRect? {
    guard let row, row.kind == .message else {
      return nil
    }
    return bubbleView.convert(bubbleView.bounds, to: view)
  }

  private func bubbleRenderCaptureRect(in view: UIView) -> CGRect {
    var captureRect = bubbleView.convert(bubbleView.bounds, to: view)
    guard let row,
      row.kind == .message,
      row.shape.showTail,
      !bubbleView.isHidden,
      tailView.isHidden
    else {
      return captureRect
    }

    let overhang = ceil(bubbleTailOverhang + 2.0)
    if row.shape.isMe {
      captureRect.size.width += overhang
    } else {
      captureRect.origin.x -= overhang
      captureRect.size.width += overhang
    }
    // Tip sits slightly below the plate (reference-extracted path).
    captureRect.size.height += ceil(bubbleTailBottomOverhang + 1.0)
    return captureRect
  }

  func reactionBadgeCenter(for emoji: String? = nil, in view: UIView) -> CGPoint? {
    guard row?.kind == .message else {
      return nil
    }
    contentView.layoutIfNeeded()
    if let emoji, !reactionStripView.isHidden,
      let center = reactionStripView.landingCenter(for: emoji, in: view)
    {
      return center
    }
    let bubbleRect = bubbleView.convert(bubbleView.bounds, to: view)
    let frame = reactionBadgeFrame(in: bubbleRect)
    return CGPoint(x: frame.midX, y: frame.midY)
  }

  func containsReactionPoint(_ point: CGPoint, in view: UIView) -> Bool {
    guard !reactionStripView.isHidden else { return false }
    return reactionStripView.convert(reactionStripView.bounds, to: view).contains(point)
  }

  /// Where the reaction pill sits, so the context menu can tell a tap on it from a
  /// tap on the bubble it is snapshotted into.
  func reactionStripFrame(in view: UIView) -> CGRect? {
    guard row?.kind == .message, !reactionStripView.isHidden else { return nil }
    let frame = reactionStripView.convert(reactionStripView.bounds, to: view)
    return frame.width > 1.0 && frame.height > 1.0 ? frame : nil
  }

  func playReactionLandingEffect(_ emoji: String, in view: UIView) -> Bool {
    guard !reactionStripView.isHidden,
      let point = reactionStripView.landingCenter(for: emoji, in: view)
    else { return false }
    reactionStripView.playLandingPulse(for: emoji)
    ChatReactionFxModule.shared.playLandingEffect(
      emoji: emoji, at: point, in: view, tintOverride: nil)
    return true
  }

  func bubbleSnapshotView(in view: UIView) -> UIView? {
    guard let row = row, row.kind == .message else {
      return nil
    }
    // A capture taken with a stale extraction still applied returns blank pixels, so the
    // menu would open on an empty bubble. Any leftover hold is stale by the time we re-open.
    if isContextMenuExtracted || hasSavedExtractionState {
      setContextMenuExtracted(false)
      contentView.layoutIfNeeded()
    }

    var captureRect = bubbleRenderCaptureRect(in: contentView)
    if !tailView.isHidden {
      let tailRect = tailView.convert(tailView.bounds, to: contentView)
      captureRect = captureRect.union(tailRect)
    }
    if !reactionStripView.isHidden {
      let reactionRect = reactionStripView.convert(reactionStripView.bounds, to: contentView)
      captureRect = captureRect.union(reactionRect)
    }
    captureRect = captureRect.integral

    guard captureRect.width > 1.0, captureRect.height > 1.0 else {
      return nil
    }

    // Take snapshot without altering contentView.transform which cancels active hold animations
    let frameInWindow = contentView.convert(captureRect, to: view)

    guard
      let snapshot = contentView.resizableSnapshotView(
        from: captureRect,
        afterScreenUpdates: false,
        withCapInsets: .zero
      )
    else {
      return nil
    }

    snapshot.frame = frameInWindow

    snapshot.clipsToBounds = false

    return snapshot
  }

  /// Captures the exact rendered bubble/tail/reaction pixels into a bitmap. The
  /// deletion effect tiles this one image using CALayer.contentsRect, so every
  /// fragment remains a real piece of the message instead of a generic particle
  /// drawn over a separately fading cell.
  func bubbleSnapshotImage(in view: UIView) -> (image: UIImage, frame: CGRect)? {
    guard let row, row.kind == .message else { return nil }

    var captureRect = bubbleRenderCaptureRect(in: contentView)
    if !tailView.isHidden {
      captureRect = captureRect.union(tailView.convert(tailView.bounds, to: contentView))
    }
    if !reactionStripView.isHidden {
      captureRect = captureRect.union(
        reactionStripView.convert(reactionStripView.bounds, to: contentView))
    }
    captureRect = captureRect.integral
    guard captureRect.width > 1.0, captureRect.height > 1.0 else { return nil }

    contentView.layoutIfNeeded()
    let format = UIGraphicsImageRendererFormat()
    format.scale = window?.screen.scale ?? UIScreen.main.scale
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: captureRect.size, format: format)
    let image = renderer.image { _ in
      contentView.drawHierarchy(
        in: CGRect(
          x: -captureRect.minX,
          y: -captureRect.minY,
          width: contentView.bounds.width,
          height: contentView.bounds.height
        ),
        afterScreenUpdates: false
      )
    }
    return (image, contentView.convert(captureRect, to: view))
  }

  private func reactionBadgeFrame(in bubbleFrame: CGRect, trailingReserve: CGFloat = 0.0)
    -> CGRect
  {
    let maxBadgeWidth = max(
      20.0,
      bubbleFrame.width - Self.reactionBadgeInsetLeft - 4.0 - trailingReserve
    )
    let measured = reactionStripMeasuredSize(
      row?.reactions ?? [], maxWidth: maxBadgeWidth,
      showsCount: row?.isGroupOrChannel == true)
    let width = measured.width
    let height = measured.height
    return CGRect(
      x: bubbleFrame.minX + Self.reactionBadgeInsetLeft,
      y: bubbleFrame.maxY - Self.reactionBadgeInsetBottom - height,
      width: width,
      height: height
    )
  }

  func transitionBubbleCaptureRects() -> (
    bubbleBodyRect: CGRect, bubbleAnchor: CGPoint, plateRect: CGRect, tailRect: CGRect,
    contentRect: CGRect, metaRect: CGRect
  )? {
    guard row?.kind == .message else {
      return nil
    }
    contentView.layoutIfNeeded()

    // `bubbleAnchor` is the TRUE (un-rounded) bubble origin. The morph maps
    // overlay content into the container by subtracting this — NOT the
    // integral box origin — because the container lands on the real cell's
    // true bubble rect. Anchoring to the integral box shifts everything by
    // the floor/ceil fringe (≤1px), which showed up as the tail sitting ~1px
    // low against the revealed cell during the completion crossfade.
    let bubbleAnchor = bubbleView.convert(CGPoint.zero, to: contentView)
    let bubbleBodyRect = bubbleView.convert(bubbleView.bounds, to: contentView).integral
    guard bubbleBodyRect.width > 1.0, bubbleBodyRect.height > 1.0 else {
      return nil
    }
    // The tail is kept OUT of the plate rect: the plate snapshot gets
    // width/height-morphed from the composer pill, and a baked-in tail would
    // stretch with it — visible as the tail growing until the very end of the
    // morph. Integrated-tail bubbles (normal text) hand out a body-only plate
    // (the plate render suppresses the tail from the bubble path, see
    // renderBubbleChromeImage) and the tail lobe is snapshotted separately by
    // transitionTailSnapshotView.
    var plateRect = bubbleRenderCaptureRect(in: contentView).integral
    // Tail rect is kept at its TRUE (sub-pixel) frame — no .integral. Rounding
    // it up expands the height by up to a full pixel, which stretches the tail
    // raster during the morph and lands with a ~1px height snap when the real
    // vector tail is revealed.
    var tailRect = CGRect.null
    if !tailView.isHidden {
      tailRect = tailView.convert(tailView.bounds, to: contentView)
    } else if bubbleView.integratedTailLobePath() != nil {
      plateRect = bubbleBodyRect
    }

    var contentRect = CGRect.null
    if !messageLabel.isHidden {
      contentRect = contentRect.union(messageLabel.frame)
    }
    if let panel = _agentTurnContentView, !panel.isHidden {
      contentRect = contentRect.union(panel.frame)
    }
    if !richTextView.isHidden {
      contentRect = contentRect.union(richTextView.frame)
    }
    if !replyPreviewView.isHidden {
      contentRect = contentRect.union(replyPreviewView.frame)
    }
    if let preview = _linkPreviewView, !preview.isHidden {
      contentRect = contentRect.union(preview.frame)
    }
    if !mediaContainerView.isHidden {
      contentRect = contentRect.union(mediaContainerView.frame)
    }
    if !inlineAttachmentView.isHidden {
      contentRect = contentRect.union(inlineAttachmentView.frame)
    }
    // Meta (timestamp/status) is kept out of the content rect: the send morph
    // moves and crossfades the text, while meta fades in separately at its
    // final placement.
    var metaRect = CGRect.null
    if !metaContainerView.isHidden {
      metaRect = metaContainerView.frame.integral
    }
    if contentRect.isNull || contentRect.width <= 1.0 || contentRect.height <= 1.0 {
      contentRect = bubbleBodyRect.insetBy(
        dx: bubbleHorizontalPadding,
        dy: min(bubbleTopPadding, bubbleBottomPadding)
      )
    }
    contentRect = contentRect.integral
    return (bubbleBodyRect, bubbleAnchor, plateRect, tailRect, contentRect, metaRect)
  }

  /// Pixel-clean text material for a send transition.
  ///
  /// `messageLabel` is a UITextView so normal messages can keep TextKit layout and link
  /// hit-testing. Rasterizing that view for the first send also rasterizes UIKit's
  /// private editor/selection layers; iOS 26 can retain one of those layers even though
  /// the view is non-editable and non-selectable, which is the dark "selected word"
  /// rectangle seen behind a one-word message. The transition does not need an editor,
  /// so reproduce the already-laid-out attributed string with a plain UILabel.
  func transitionCleanTextSnapshotView(
    captureRect: CGRect, targetFrame: CGRect
  ) -> UIView? {
    guard let row, row.kind == .message, row.visualKind == .text,
      !row.isAgentMessage,
      !messageLabel.isHidden,
      _agentTurnContentView?.isHidden ?? true,
      richTextView.isHidden,
      replyPreviewView.isHidden,
      _linkPreviewView?.isHidden ?? true,
      inlineAttachmentView.isHidden,
      mediaContainerView.isHidden,
      let attributed = messageLabel.attributedText,
      attributed.length > 0,
      captureRect.width > 1.0,
      captureRect.height > 1.0
    else {
      return nil
    }

    let clean = NSMutableAttributedString(attributedString: attributed)
    var transientKeys = Set<NSAttributedString.Key>()
    clean.enumerateAttributes(
      in: NSRange(location: 0, length: clean.length),
      options: []
    ) { attributes, _, _ in
      for key in attributes.keys {
        let raw = key.rawValue.lowercased()
        if key == .backgroundColor
          || raw.contains("selection")
          || raw.contains("marked")
          || raw.contains("highlight")
        {
          transientKeys.insert(key)
        }
      }
    }
    for key in transientKeys {
      clean.removeAttribute(key, range: NSRange(location: 0, length: clean.length))
    }

    let wrapper = UIView(frame: targetFrame)
    wrapper.backgroundColor = .clear
    wrapper.isOpaque = false
    wrapper.isUserInteractionEnabled = false
    wrapper.clipsToBounds = false

    let label = UILabel()
    label.backgroundColor = .clear
    label.isOpaque = false
    label.isUserInteractionEnabled = false
    label.numberOfLines = messageLabel.numberOfLines
    label.lineBreakMode = messageLabel.textContainer.lineBreakMode
    label.textAlignment = messageLabel.textAlignment
    label.semanticContentAttribute = messageLabel.semanticContentAttribute
    label.attributedText = clean
    label.frame = messageLabel.frame.offsetBy(
      dx: -captureRect.minX,
      dy: -captureRect.minY
    )
    wrapper.addSubview(label)

    NSLog(
      "[SendMorphDiag] clean destination text mid=%@ len=%d removedAttrs=%@ selected=%d:%d marked=%@ firstResponder=%@ frame=%@ capture=%@",
      String((row.messageId ?? row.key).prefix(12)),
      clean.length,
      transientKeys.map(\.rawValue).sorted().joined(separator: ","),
      messageLabel.selectedRange.location,
      messageLabel.selectedRange.length,
      messageLabel.markedTextRange != nil ? "Y" : "N",
      messageLabel.isFirstResponder ? "Y" : "N",
      NSCoder.string(for: messageLabel.frame),
      NSCoder.string(for: captureRect)
    )
    return wrapper
  }

  func bubbleBackgroundSnapshotView(in view: UIView) -> UIView? {
    guard row?.kind == .message else {
      return nil
    }
    guard let capture = transitionBubbleCaptureRects() else {
      return nil
    }
    // Plate only — the tail is snapshotted separately by the send morph so it
    // is never stretched by the width/height animation. For integrated-tail
    // bubbles the render below suppresses the tail from the bubble path itself.
    let captureRect = capture.plateRect
    guard captureRect.width > 1.0, captureRect.height > 1.0 else {
      return nil
    }
    let image = renderBubbleChromeImage(captureRect: captureRect, suppressIntegratedTail: true)
    let imageView = UIImageView(image: resizableTransitionPlateImage(image))
    imageView.frame = contentView.convert(captureRect, to: view)
    imageView.contentMode = .scaleToFill
    imageView.backgroundColor = .clear
    imageView.isOpaque = false
    imageView.clipsToBounds = false
    return imageView
  }

  /// 9-part version of the plate raster: cap insets cover the corner radii so
  /// the send morph's width/height animation stretches only the flat middle
  /// bands — the baked destination corners stay
  /// pixel-true at every intermediate size instead of being scaled with the
  /// bounds. This is also what keeps the tail lobe's splice arc stable: the
  /// bottom corner it rides is the real destination arc for the whole flight.
  private func resizableTransitionPlateImage(_ image: UIImage) -> UIImage {
    let radii = bubbleView.transitionCornerRadii()
    var top = max(radii.topLeft, radii.topRight) + 1.0
    var bottom = max(radii.bottomLeft, radii.bottomRight) + 1.0
    var left = max(radii.topLeft, radii.bottomLeft) + 1.0
    var right = max(radii.topRight, radii.bottomRight) + 1.0
    let maxVertical = max(0.0, image.size.height - 1.0)
    let maxHorizontal = max(0.0, image.size.width - 1.0)
    if top + bottom > maxVertical, top + bottom > 0.0 {
      let scale = maxVertical / (top + bottom)
      top *= scale
      bottom *= scale
    }
    if left + right > maxHorizontal, left + right > 0.0 {
      let scale = maxHorizontal / (left + right)
      left *= scale
      right *= scale
    }
    return image.resizableImage(
      withCapInsets: UIEdgeInsets(top: top, left: left, bottom: bottom, right: right),
      resizingMode: .stretch
    )
  }

  /// Send-morph tail snapshot for integrated-tail bubbles (normal text). The
  /// plate raster is captured with the tail suppressed so the morph stretches a
  /// clean rounded plate; this returns the missing piece — the cell rendered
  /// WITH the tail, masked to the lobe the tail adds outside the plain corner
  /// arc. Plate ∪ lobe reproduces the real bubble render exactly, so revealing
  /// the real cell at completion cannot shift a single pixel. The returned
  /// frame is in contentView coordinates; the morph pins it at final placement.
  func transitionTailSnapshotView() -> (view: UIView, frameInContent: CGRect)? {
    guard row?.kind == .message else {
      return nil
    }
    guard tailView.isHidden, let lobePath = bubbleView.integratedTailLobePath() else {
      return nil
    }
    contentView.layoutIfNeeded()
    let lobeBoundsInBubble = lobePath.bounds.insetBy(dx: -2.0, dy: -2.0)
    let captureRect = pixelAlignedRect(bubbleView.convert(lobeBoundsInBubble, to: contentView))
    guard captureRect.width > 1.0, captureRect.height > 1.0 else {
      return nil
    }
    // The lobe overhangs the cell's trailing edge (5.3pt at radius 18; up to 7.7pt),
    // past contentView.bounds) and drawHierarchy clips at the canvas bounds —
    // rendering from contentView shipped a raster with the tail's outer hook
    // MISSING, so the morph flew a visibly clipped tail that "completed" only
    // when the real cell was revealed. The snapshot cell lives alone inside the
    // full-width transition overlay host during capture; render from there.
    let image = renderBubbleChromeImage(
      captureRect: captureRect, suppressIntegratedTail: false, canvasView: superview)
    let imageView = UIImageView(image: image)
    imageView.frame = captureRect
    imageView.contentMode = .scaleToFill
    imageView.backgroundColor = .clear
    imageView.isOpaque = false
    imageView.clipsToBounds = false
    // Mask to the lobe so these pixels never double-paint over the
    // (tail-suppressed) plate snapshot; the hairline stroke widens the mask by
    // ~0.75pt so it covers the plate raster's anti-aliased arc edge instead of
    // meeting it in a see-through seam.
    let bubbleOrigin = bubbleView.convert(CGPoint.zero, to: contentView)
    let maskPath = UIBezierPath(cgPath: lobePath.cgPath)
    maskPath.apply(
      CGAffineTransform(
        translationX: bubbleOrigin.x - captureRect.minX,
        y: bubbleOrigin.y - captureRect.minY
      ))
    let mask = CAShapeLayer()
    mask.contentsScale = UIScreen.main.scale
    mask.frame = CGRect(origin: .zero, size: captureRect.size)
    mask.path = maskPath.cgPath
    mask.fillColor = UIColor.black.cgColor
    mask.strokeColor = UIColor.black.cgColor
    mask.lineWidth = 1.5
    imageView.layer.mask = mask
    NSLog(
      "[SendMorphDiag] tail raster mid=%@ capture=%@ lobe=%@ alpha=%@",
      String((row?.messageId ?? row?.key ?? "-").prefix(12)),
      NSCoder.string(for: captureRect),
      NSCoder.string(for: lobePath.bounds),
      transitionImageAlphaSummary(image)
    )
    return (imageView, captureRect)
  }

  private func transitionImageAlphaSummary(_ image: UIImage) -> String {
    guard let cgImage = image.cgImage else { return "no-cg" }
    let width = cgImage.width
    let height = cgImage.height
    guard width > 0, height > 0 else { return "empty" }

    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
      guard let base = bytes.baseAddress,
        let context = CGContext(
          data: base,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo:
            CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        )
      else {
        return false
      }
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard rendered else { return "context-failed" }

    var nonzero = 0
    var maxAlpha = 0
    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1
    for y in 0..<height {
      for x in 0..<width {
        let alpha = Int(pixels[(y * width + x) * 4 + 3])
        maxAlpha = max(maxAlpha, alpha)
        guard alpha > 2 else { continue }
        nonzero += 1
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
      }
    }
    let pixelBounds =
      nonzero > 0
      ? "\(minX),\(minY)-\(maxX),\(maxY)"
      : "none"
    return "\(nonzero)/\(width * height) max=\(maxAlpha) bounds=\(pixelBounds)"
  }

  /// Renders the bubble chrome (plate, wallpaper backdrop, gradient) with every
  /// content view hidden. `suppressIntegratedTail` re-applies the bubble path
  /// WITHOUT the integrated tail for the duration of the render — the send
  /// morph width/height-stretches that raster, and a baked-in tail would
  /// stretch (and land with a visible shift) along with it.
  private func renderBubbleChromeImage(
    captureRect: CGRect, suppressIntegratedTail: Bool, canvasView: UIView? = nil
  ) -> UIImage {
    let messageWasHidden = messageLabel.isHidden
    let richTextWasHidden = richTextView.isHidden
    let replyWasHidden = replyPreviewView.isHidden
    let previewWasHidden = _linkPreviewView?.isHidden ?? true
    let mediaWasHidden = mediaContainerView.isHidden
    let attachmentWasHidden = inlineAttachmentView.isHidden
    let metaWasHidden = metaContainerView.isHidden
    let tailWasHidden = tailView.isHidden

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    messageLabel.isHidden = true
    richTextView.isHidden = true
    replyPreviewView.isHidden = true
    _linkPreviewView?.isHidden = true
    mediaContainerView.isHidden = true
    inlineAttachmentView.isHidden = true
    metaContainerView.isHidden = true
    tailView.isHidden = true
    contentView.layoutIfNeeded()
    CATransaction.commit()

    // After the layout flush, so a pending layout pass can't re-enable the
    // integrated tail (the cell layout owns setIntegratedTailEnabled).
    let suppressTail = suppressIntegratedTail && bubbleView.integratedTailLobePath() != nil
    if suppressTail {
      bubbleView.setIntegratedTailEnabled(false)
    }

    defer {
      if suppressTail {
        bubbleView.setIntegratedTailEnabled(true)
      }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      messageLabel.isHidden = messageWasHidden
      richTextView.isHidden = richTextWasHidden
      replyPreviewView.isHidden = replyWasHidden
      _linkPreviewView?.isHidden = previewWasHidden
      mediaContainerView.isHidden = mediaWasHidden
      inlineAttachmentView.isHidden = attachmentWasHidden
      metaContainerView.isHidden = metaWasHidden
      tailView.isHidden = tailWasHidden
      contentView.layoutIfNeeded()
      CATransaction.commit()
    }

    // captureRect is in contentView coordinates; the raster is drawn from
    // `canvas` — drawHierarchy CLIPS at the canvas view's bounds, and the
    // integrated tail overhangs the cell's trailing edge by up to ~7.7pt, so the tail
    // snapshot must render from a wider ancestor (see transitionTailSnapshotView)
    // or the raster ships with the tail's outer hook cut off.
    let canvas = canvasView ?? contentView
    let rectInCanvas = contentView.convert(captureRect, to: canvas)
    // .preferred() matches the main screen's color space (Display P3 on device).
    // The plain default bakes to sRGB, which visibly dulls the saturated bubble
    // gradient — seen as a soft whole-bubble color jump when the raster overlay
    // is swapped for the live cell at the end of the send morph.
    let format = UIGraphicsImageRendererFormat.preferred()
    format.opaque = false
    format.scale = UIScreen.main.scale
    let renderer = UIGraphicsImageRenderer(size: rectInCanvas.size, format: format)
    let image = renderer.image { context in
      if canvasView != nil {
        // The wider ancestor is an offscreen transition-capture canvas. UIKit may
        // report drawHierarchy success for that canvas while emitting transparent
        // pixels because it has never participated in a screen transaction—the exact
        // first-message tail failure. CALayer rendering is deterministic offscreen.
        context.cgContext.translateBy(x: -rectInCanvas.minX, y: -rectInCanvas.minY)
        canvas.layer.render(in: context.cgContext)
      } else {
        // drawHierarchy fails (returns false, leaving the image fully transparent)
        // when the cell hasn't been committed to the screen yet. Fall back to
        // layer.render so the bubble plate is never blank during the send morph.
        let drewHierarchy = canvas.drawHierarchy(
          in: CGRect(
            x: -rectInCanvas.minX,
            y: -rectInCanvas.minY,
            width: canvas.bounds.width,
            height: canvas.bounds.height
          ),
          afterScreenUpdates: true
        )
        if !drewHierarchy {
          context.cgContext.translateBy(x: -rectInCanvas.minX, y: -rectInCanvas.minY)
          canvas.layer.render(in: context.cgContext)
        }
      }
    }
    return image
  }
}

final class BubbleTailView: UIView {
  private let wallpaperLayer = CALayer()
  private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
  private let gradientLayer = CAGradientLayer()
  private let fillLayer = CAShapeLayer()
  private let tailMaskLayer = CAShapeLayer()
  private let clipMaskLayer = CAShapeLayer()
  private var currentIsMe: Bool = true
  private var appearance = ChatListAppearance.current
  private var wallpaperSnapshot: CGImage?
  private var wallpaperContainerSize: CGSize = .zero
  private var wallpaperSampleRect: CGRect = .zero
  let imageView = UIImageView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    clipsToBounds = false

    wallpaperLayer.contentsGravity = .resize
    wallpaperLayer.contentsScale = UIScreen.main.scale
    layer.addSublayer(wallpaperLayer)
    addSubview(blurView)
    addSubview(imageView)
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.isHidden = true
    layer.addSublayer(gradientLayer)
    gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
    gradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
    layer.addSublayer(fillLayer)
    layer.mask = tailMaskLayer

    // Shape layers (and layer masks) rasterize at contentsScale 1.0 by default, so on a
    // 2x/3x display the tail's curved edge is drawn at 1px then scaled up — that's the
    // jagged/low-res tail. Pin every shaping layer to the screen scale for a crisp edge.
    let screenScale = UIScreen.main.scale
    fillLayer.contentsScale = screenScale
    tailMaskLayer.contentsScale = screenScale
    clipMaskLayer.contentsScale = screenScale
    gradientLayer.contentsScale = screenScale
  }

  func setImage(_ image: UIImage?) {
    imageView.image = image
    imageView.isHidden = image == nil
    blurView.isHidden = image != nil
    fillLayer.isHidden = image != nil
    wallpaperLayer.isHidden = image != nil || wallpaperSnapshot == nil
    // The normal me/them tail is a solid fillLayer now (see applyTailChrome); only the agent
    // tail uses gradientLayer, and it re-enables that itself in applyAgentTailStyle. So keep
    // the gradient hidden here regardless of sender — a stale reveal would re-introduce the
    // rotated-gradient color seam we removed.
    gradientLayer.isHidden = true
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func configure(isMe: Bool, visible: Bool, appearance: ChatListAppearance) {
    currentIsMe = isMe
    self.appearance = appearance
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    applyTailChrome(isMe: isMe, visible: visible)
    applyWallpaperBackdropLayer()
    CATransaction.commit()
    setNeedsLayout()
  }

  func applyAgentTailStyle(
    appearance: ChatListAppearance,
    isMe: Bool,
    accent accentOverride: UIColor? = nil
  ) {
    // Accent kept for API parity with body agent style; them fill no longer washes with it.
    _ = accentOverride
    let hasWallpaperBackdrop =
      wallpaperSnapshot != nil
      && wallpaperContainerSize.width > 1.0
      && wallpaperContainerSize.height > 1.0
      && appearance.backgroundMode != "transparent"
      && imageView.image == nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    // Match bubble body: them tails use the same stable wallpaper plate (no agent wash
    // recolor). Me tails keep the shared me gradient path.
    if !isMe {
      gradientLayer.isHidden = true
      gradientLayer.opacity = 0.0
      let plateSample =
        wallpaperSampleRect.width > 1 && wallpaperSampleRect.height > 1
        ? wallpaperSampleRect
        : CGRect(x: 0, y: 0, width: 1, height: 1)
      let plateContainer =
        wallpaperContainerSize.width > 1 && wallpaperContainerSize.height > 1
        ? wallpaperContainerSize
        : CGSize(width: 1, height: 1)
      let plateColor = appearance.wallpaperPlateColor(
        isMe: false,
        sampleRect: plateSample,
        containerSize: plateContainer
      )
      fillLayer.fillColor = plateColor.withAlphaComponent(appearance.incomingPlateFillOpacity).cgColor
      blurView.alpha = 0.0
    } else {
      if hasWallpaperBackdrop {
        gradientLayer.isHidden = true
        gradientLayer.opacity = 0.0
        // Me underfill stays clear — body gradient paints the continuous ramp.
        fillLayer.fillColor = UIColor.clear.cgColor
      } else {
        gradientLayer.isHidden = false
        gradientLayer.colors = appearance.bubbleMeGradient.map(\.cgColor)
        gradientLayer.opacity = 0.82
      }
      blurView.alpha = 0.0
    }
    CATransaction.commit()
  }

  func clearAgentTailStyle() {
    // No-op: regular configure resets everything
  }

  func applyWallpaperBackdrop(
    snapshot: CGImage?,
    containerSize: CGSize,
    sampleRect: CGRect
  ) {
    let prevHas =
      wallpaperSnapshot != nil
      && wallpaperContainerSize.width > 1.0
      && wallpaperContainerSize.height > 1.0
    let nextHas =
      snapshot != nil
      && containerSize.width > 1.0
      && containerSize.height > 1.0
    let sampleOnly = prevHas == nextHas
    wallpaperSnapshot = snapshot
    wallpaperContainerSize = containerSize
    wallpaperSampleRect = sampleRect
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if sampleOnly {
      applyWallpaperBackdropLayer()
    } else {
      applyTailChrome(isMe: currentIsMe, visible: !isHidden)
      applyWallpaperBackdropLayer()
    }
    CATransaction.commit()
    if !sampleOnly {
      setNeedsLayout()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.width > 0, bounds.height > 0 else { return }

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    blurView.frame = bounds
    imageView.frame = bounds
    wallpaperLayer.frame = bounds
    gradientLayer.frame = bounds
    fillLayer.frame = bounds

    // Tail path in 29×29 coordinate space.
    let basePath = UIBezierPath()
    basePath.move(to: CGPoint(x: 0, y: 0))
    basePath.addQuadCurve(to: CGPoint(x: 14, y: 25), controlPoint: CGPoint(x: -5, y: 22))
    basePath.addQuadCurve(to: CGPoint(x: 0, y: 29), controlPoint: CGPoint(x: 10.5, y: 29))
    basePath.close()

    let scale = CGAffineTransform(scaleX: bounds.width / 29.0, y: bounds.height / 29.0)
    basePath.apply(scale)

    fillLayer.path = basePath.cgPath

    // Use the tail shape as mask for the entire view (blur + gradient + fill)
    // but clip the top ~40% where the thin closing line is visible.
    let clipTop = bounds.height * 0.4
    let clippedPath = UIBezierPath()
    clippedPath.move(to: CGPoint(x: 0, y: 0))
    clippedPath.addQuadCurve(to: CGPoint(x: 14, y: 25), controlPoint: CGPoint(x: -5, y: 22))
    clippedPath.addQuadCurve(to: CGPoint(x: 0, y: 29), controlPoint: CGPoint(x: 10.5, y: 29))
    clippedPath.close()
    clippedPath.apply(CGAffineTransform(scaleX: bounds.width / 29.0, y: bounds.height / 29.0))

    // Create compound mask: tail shape intersected with bottom clip rect
    let combinedPath = UIBezierPath(
      rect: CGRect(x: -5, y: clipTop, width: bounds.width + 10, height: bounds.height - clipTop + 5)
    )
    combinedPath.usesEvenOddFillRule = false

    tailMaskLayer.frame = bounds
    tailMaskLayer.path = clippedPath.cgPath

    // Also clip to bottom portion
    let clipLayer = CAShapeLayer()
    clipLayer.contentsScale = UIScreen.main.scale
    clipLayer.frame = bounds
    clipLayer.path =
      UIBezierPath(
        rect: CGRect(
          x: -5, y: clipTop, width: bounds.width + 10, height: bounds.height - clipTop + 5)
      ).cgPath
    tailMaskLayer.mask = clipLayer

    // Gradient mask for me bubbles
    if !gradientLayer.isHidden {
      let gradMask = CAShapeLayer()
      gradMask.contentsScale = UIScreen.main.scale
      gradMask.frame = bounds
      gradMask.path = basePath.cgPath
      gradientLayer.mask = gradMask
    }

    applyWallpaperBackdropLayer()

    CATransaction.commit()
  }

  private func applyWallpaperBackdropLayer() {
    let hasBackdrop =
      imageView.image == nil
      && wallpaperSnapshot != nil
      && wallpaperContainerSize.width > 1.0
      && wallpaperContainerSize.height > 1.0
      && appearance.backgroundMode != "transparent"

    wallpaperLayer.isHidden = !hasBackdrop
    guard hasBackdrop, let wallpaperSnapshot else {
      wallpaperLayer.contents = nil
      return
    }

    wallpaperLayer.contents = wallpaperSnapshot
    wallpaperLayer.contentsRect = normalizedWallpaperSampleRect(
      wallpaperSampleRect,
      containerSize: wallpaperContainerSize
    )
  }

  private func applyTailChrome(isMe: Bool, visible: Bool) {
    let hasWallpaperBackdrop =
      wallpaperSnapshot != nil
      && wallpaperContainerSize.width > 1.0
      && wallpaperContainerSize.height > 1.0
      && appearance.backgroundMode != "transparent"
      && imageView.image == nil

    isHidden = !visible

    // Keep tail styling in lockstep with BubbleBackgroundView so both read as one shape.
    wallpaperLayer.isHidden = !hasWallpaperBackdrop
    wallpaperLayer.opacity = Float(
      hasWallpaperBackdrop
        ? (isMe ? appearance.outgoingWallpaperSampleOpacity : appearance.incomingWallpaperSampleOpacity)
        : 1.0
    )
    let material: UIBlurEffect.Style =
      appearance.isDark
      ? (isMe ? .systemThinMaterialDark : .systemMaterialDark)
      : (isMe ? .systemThinMaterialLight : .systemMaterialLight)
    blurView.effect = UIBlurEffect(style: material)
    // Same as body: them plate is stable with/without wallpaper (no solid→plate flash).
    let materialAlpha: CGFloat
    if hasWallpaperBackdrop {
      materialAlpha = 0.0
    } else if isMe {
      materialAlpha = 0.34
    } else {
      materialAlpha = 0.0
    }
    blurView.alpha = materialAlpha
    gradientLayer.isHidden = true
    gradientLayer.opacity = 0.0
    if isMe {
      // Body paints the shared me gradient; tail junction stays a solid mid plate so
      // the rotated lobe doesn't desync from the continuous ramp.
      if hasWallpaperBackdrop {
        let plateColor = appearance.wallpaperPlateColor(
          isMe: true,
          sampleRect: wallpaperSampleRect,
          containerSize: wallpaperContainerSize
        )
        fillLayer.fillColor = plateColor.withAlphaComponent(appearance.outgoingPlateFillOpacity)
          .cgColor
      } else {
        fillLayer.fillColor =
          appearance.outgoingBasePlateColor.withAlphaComponent(0.88).cgColor
      }
    } else {
      let plateSample =
        wallpaperSampleRect.width > 1 && wallpaperSampleRect.height > 1
        ? wallpaperSampleRect
        : CGRect(x: 0, y: 0, width: 1, height: 1)
      let plateContainer =
        wallpaperContainerSize.width > 1 && wallpaperContainerSize.height > 1
        ? wallpaperContainerSize
        : CGSize(width: 1, height: 1)
      let plateColor = appearance.wallpaperPlateColor(
        isMe: false,
        sampleRect: plateSample,
        containerSize: plateContainer
      )
      fillLayer.fillColor = plateColor.withAlphaComponent(appearance.incomingPlateFillOpacity)
        .cgColor
    }

    // For 'me': rotate CW 26.565° (tail curves right at bottom-right of bubble)
    // For 'them': flip horizontally + rotate CCW 26.565° (tail curves left at bottom-left)
    let angle = (isMe ? 26.565 : -26.565) * (.pi / 180.0)
    let rotate = CGAffineTransform(rotationAngle: angle)
    let flip = CGAffineTransform(scaleX: isMe ? 1.0 : -1.0, y: 1.0)
    // Translate slightly inward to bury the tail edge into the bubble body and prevent any 1px gaps
    let translate = CGAffineTransform(translationX: isMe ? -0.5 : 0.5, y: 0.0)
    transform = flip.concatenating(rotate).concatenating(translate)
  }
}

// MARK: - Send transition overlay helpers
