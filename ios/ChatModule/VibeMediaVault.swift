import Foundation
import UIKit

/// One store for every byte this app downloads: chat photos, video posters, voice notes and
/// music, documents, rendered document pages, avatars.
///
/// Before this existed, each surface had its own directory, its own cache key, and its own
/// idea of when a file was allowed to vanish. That produced three separate classes of bug:
///
/// 1. **The same bytes downloaded more than once.** A photo fetched in a chat could not be
///    found by the profile grid or the home list, because each computed a different name for
///    it. Voice and music kept two copies of one track.
/// 2. **A file already on disk re-fetched on the next open.** Chat photo names were built from
///    the full signed URL, so the moment the server re-signed the link (`?exp=…&sig=…`) every
///    name changed and every photo missed. That is the re-download — and the visible fade-in —
///    on every reopen.
/// 3. **A downloaded file lost because the ORIGIN lost it.** This app is not a feed: once the
///    user has the bytes, they own them. A server dropping an attachment must not take the
///    copy on this phone with it.
///
/// The rules that follow:
///
/// - **Identity is the stable remote identity** (`chatStableRemoteMediaIdentity` + media key) —
///   never a name derived from response headers, the query string, or a display name. Those are
///   knowable only while a response is in hand, so the next launch computes something different
///   and misses a file it already has. Two surfaces asking for the same bytes get one address.
/// - **Nothing here expires.** No TTL, no size ceiling, no eviction under memory pressure. It
///   lives in Application Support, because iOS purges `Caches` — which is what forced
///   re-downloads of media the user had already waited for. The only thing that removes a file
///   is the user asking, in Settings.
/// - **A fetch failure never deletes.** The vault answers "do I have this?" from disk, not from
///   whether the origin still agrees the file exists.
enum VibeMediaKind: String, CaseIterable {
  case image
  case videoPreview
  case audio
  case document
  case documentPage
  case avatar

  var folderName: String {
    switch self {
    case .image: return "images"
    case .videoPreview: return "video-previews"
    case .audio: return "audio"
    case .document: return "documents"
    case .documentPage: return "document-pages"
    case .avatar: return "avatars"
    }
  }

  /// A document is the one kind whose file NAME the user reads, so it gets a slot directory
  /// and keeps its name inside. Everything else is addressed by hash alone: giving those a
  /// directory each would cost an inode and a `readdir` per item for a name nobody sees.
  var preservesDisplayName: Bool { self == .document }

  var displayTitle: String {
    switch self {
    case .image: return "Photos"
    case .videoPreview: return "Video previews"
    case .audio: return "Voice & music"
    case .document: return "Documents"
    case .documentPage: return "Document previews"
    case .avatar: return "Avatars"
    }
  }
}

final class VibeMediaVault {
  static let shared = VibeMediaVault()

  struct Entry {
    let url: URL
    let kind: VibeMediaKind
    let identity: String
    let displayName: String
    let byteSize: Int64
    let modifiedAt: Date
  }

  struct Usage {
    var fileCount: Int = 0
    var byteSize: Int64 = 0
  }

  /// Guards `indexByKind` and the availability memo. Both are read from cell configure on the
  /// main thread and written from download queues, and `cachedURL` must stay cheap enough to
  /// call while a table view is scrolling.
  private let lock = NSLock()
  private var indexByKind: [VibeMediaKind: [String: URL]] = [:]
  /// Paths handed out by `destinationURL` that a caller intends to write itself. Several
  /// download paths (voice notes especially) take the destination and stream into it rather
  /// than handing the vault bytes; without remembering the promise, the file would land where
  /// nothing was looking for it and the next play would download it again.
  private var promisedByKind: [VibeMediaKind: [String: URL]] = [:]
  private var unavailableIdentities = Set<String>()
  private var failureCountByIdentity: [String: Int] = [:]
  /// Keyed legacy slots already probed this session (kind + legacy identity), under `lock`.
  private var legacyProbedKeys = Set<String>()

  /// A transport error may be a passing blip; a non-2xx is the origin's final answer. Three
  /// tries then silence, so a dead URL is not re-requested on every scroll pass.
  static let maxFetchAttempts = 3

  private init() {}

  // MARK: - Identity

  /// Media keys seen per identity this session, so a plain `cachedURL` miss can still reach
  /// the keyed slot an older build wrote. Guarded by `keyMemoLock`.
  private static let keyMemoLock = NSLock()
  private static var mediaKeyByIdentity: [String: String] = [:]

  /// The address of one piece of remote media. Stable across re-signings, across launches, and
  /// across surfaces — see the type comment for why nothing about the response may enter it.
  static func identity(remoteURL: URL, mediaKey: String? = nil) -> String {
    // One URL has one ciphertext and one key: the key decrypts, it does not address. Keying on
    // it made a row that lost its key (failed open, core frame) miss bytes already on disk.
    let identity = chatStableRemoteMediaIdentity(remoteURL)
    rememberMediaKey(mediaKey, for: identity)
    return identity
  }

  /// String form, for the many call sites that hold a raw URL string. A value that will not
  /// parse as a URL (a bare local path, a synthetic key) is used verbatim: it is already stable.
  static func identity(rawURL: String, mediaKey: String? = nil) -> String {
    let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: trimmed), url.scheme != nil {
      return identity(remoteURL: url, mediaKey: mediaKey)
    }
    rememberMediaKey(mediaKey, for: trimmed)
    return trimmed
  }

  private static func rememberMediaKey(_ mediaKey: String?, for identity: String) {
    guard let key = mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
      !identity.isEmpty
    else { return }
    keyMemoLock.lock()
    if mediaKeyByIdentity[identity] == nil { mediaKeyByIdentity[identity] = key }
    keyMemoLock.unlock()
  }

  private static func rememberedMediaKey(for identity: String) -> String? {
    keyMemoLock.lock()
    defer { keyMemoLock.unlock() }
    return mediaKeyByIdentity[identity]
  }

  /// The keyed address older builds gave this media, or nil without a non-empty key.
  static func legacyKeyedIdentity(remoteURL: URL, mediaKey: String?) -> String? {
    guard let key = mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
    else { return nil }
    return chatStableRemoteMediaIdentity(remoteURL) + "|k:" + key
  }

  private func slotName(for identity: String) -> String {
    chatStableCacheHash(identity)
  }

  // MARK: - Directories

  /// Application Support, never `Caches`. The whole point of the vault is that a file the user
  /// waited for survives until they say otherwise, and iOS reclaims `Caches` whenever it likes.
  private static let root: URL = {
    let root = vibeDurableMediaCacheRoot().appendingPathComponent("vault", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }()

  func directory(for kind: VibeMediaKind) -> URL {
    let dir = Self.root.appendingPathComponent(kind.folderName, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Directories the vault does not ADDRESS but must still account for and clear: pre-vault
  /// locations that may still hold files, and the music player's own cache — that one is keyed
  /// by track id in a database holding absolute paths, so moving its files would strand the
  /// library. We leave them where they are and only count them.
  func externalDirectories(for kind: VibeMediaKind) -> [URL] {
    let fm = FileManager.default
    let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
    let durable = vibeDurableMediaCacheRoot()
    func both(_ name: String) -> [URL] {
      var out: [URL] = [durable.appendingPathComponent(name, isDirectory: true)]
      if let caches = caches {
        out.append(caches.appendingPathComponent(name, isDirectory: true))
      }
      return out
    }
    switch kind {
    case .image: return both("chat-media-images")
    case .videoPreview: return both("chat-media-video-preview")
    case .audio:
      return both("voice-cache") + both("native-music-player-cache") + both("music_cache")
    case .document: return both("vibe-chat-preview-docs")
    case .documentPage: return both("chat-doc-page-previews")
    case .avatar: return both("vibe-avatars")
    }
  }

  /// The slot directory for a name-preserving kind. The file inside keeps its human name; the
  /// name is never part of the address.
  func slotDirectory(for identity: String, kind: VibeMediaKind, create: Bool = true) -> URL {
    let slot = directory(for: kind).appendingPathComponent(
      slotName(for: identity), isDirectory: true)
    if create {
      try? FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
    }
    return slot
  }

  // MARK: - Index

  /// Built once per kind from a single directory listing, so `cachedURL` is a dictionary lookup
  /// and never a syscall. The old code ran `fileExists` per media row per configure pass.
  private func index(for kind: VibeMediaKind) -> [String: URL] {
    lock.lock()
    if let existing = indexByKind[kind] {
      lock.unlock()
      return existing
    }
    lock.unlock()

    var built: [String: URL] = [:]
    let fm = FileManager.default
    let dir = directory(for: kind)
    let items =
      (try? fm.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))
      ?? []
    for item in items {
      if kind.preservesDisplayName {
        guard item.hasDirectoryPath else { continue }
        guard let file = Self.firstRegularFile(in: item) else { continue }
        built[item.lastPathComponent] = file
      } else {
        guard !item.hasDirectoryPath else { continue }
        built[item.deletingPathExtension().lastPathComponent] = item
      }
    }

    lock.lock()
    // A concurrent build may have finished first; its entries plus any write that landed
    // meanwhile are at least as fresh as ours.
    if let existing = indexByKind[kind] {
      lock.unlock()
      return existing
    }
    indexByKind[kind] = built
    lock.unlock()
    return built
  }

  private static func firstRegularFile(in directory: URL) -> URL? {
    guard
      let items = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles])
    else { return nil }
    return items.first {
      (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }
  }

  private func recordInIndex(_ url: URL, kind: VibeMediaKind, identity: String) {
    let slot = slotName(for: identity)
    lock.lock()
    if indexByKind[kind] != nil {
      indexByKind[kind]?[slot] = url
    }
    lock.unlock()
  }

  private func dropFromIndex(kind: VibeMediaKind, identity: String) {
    let slot = slotName(for: identity)
    lock.lock()
    indexByKind[kind]?.removeValue(forKey: slot)
    lock.unlock()
  }

  // MARK: - Lookup

  /// The file for this identity, or nil. Disk only — this never touches the network, so it is
  /// safe from cell configure and from layout.
  ///
  /// `legacyCandidates` are paths written by a pre-vault layout. They are only consulted on a
  /// miss (the moment we were about to hit the network anyway) and a hit is moved into the vault,
  /// so the library the user already downloaded is carried forward instead of re-fetched.
  func cachedURL(
    for identity: String, kind: VibeMediaKind, legacyCandidates: [URL] = []
  ) -> URL? {
    let slot = slotName(for: identity)
    if let hit = index(for: kind)[slot] {
      // The index is authoritative right up until something outside the app removes a file
      // (a Settings clear, the user deleting the container). Verify cheaply rather than hand
      // back a path that no longer resolves.
      if FileManager.default.fileExists(atPath: hit.path) { return hit }
      dropFromIndex(kind: kind, identity: identity)
    }
    // A path we promised a caller: real once the bytes land, and kept promised until then so a
    // download still in flight is not mistaken for a permanent absence.
    lock.lock()
    let promised = promisedByKind[kind]?[slot]
    lock.unlock()
    if let promised = promised, FileManager.default.fileExists(atPath: promised.path) {
      recordInIndex(promised, kind: kind, identity: identity)
      return promised
    }
    // A caller that ever passed a media key for this identity self-heals the keyed slot.
    if let key = Self.rememberedMediaKey(for: identity),
      let adopted = adoptLegacyKeyed(
        legacyIdentity: identity + "|k:" + key, identity: identity, kind: kind)
    {
      return adopted
    }
    for candidate in legacyCandidates {
      guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
      if let adopted = adopt(
        fileAt: candidate, for: identity, kind: kind, displayName: candidate.lastPathComponent,
        move: true)
      {
        return adopted
      }
    }
    return nil
  }

  func contains(_ identity: String, kind: VibeMediaKind) -> Bool {
    cachedURL(for: identity, kind: kind) != nil
  }

  // MARK: - Keyed legacy slots

  /// What an older build stored under the keyed address: the slot file for a hash-named kind,
  /// the slot directory for `.document`. Only entries that exist on disk.
  func legacyKeyedCandidateURLs(remoteURL: URL, mediaKey: String?, kind: VibeMediaKind) -> [URL]
  {
    guard let legacy = Self.legacyKeyedIdentity(remoteURL: remoteURL, mediaKey: mediaKey)
    else { return [] }
    return legacyKeyedCandidateURLs(legacyIdentity: legacy, kind: kind)
  }

  private func legacyKeyedCandidateURLs(legacyIdentity: String, kind: VibeMediaKind) -> [URL] {
    let fm = FileManager.default
    let legacySlot = slotName(for: legacyIdentity)
    if kind.preservesDisplayName {
      let dir = directory(for: kind).appendingPathComponent(legacySlot, isDirectory: true)
      return fm.fileExists(atPath: dir.path) ? [dir] : []
    }
    // The index is keyed by basename, so it answers for whatever extension the file carries.
    guard let file = index(for: kind)[legacySlot], fm.fileExists(atPath: file.path) else {
      return []
    }
    return [file]
  }

  /// Moves the keyed-slot file to the current address and returns it, or nil when none exists.
  @discardableResult
  func adoptLegacyKeyed(remoteURL: URL, mediaKey: String?, kind: VibeMediaKind) -> URL? {
    guard let legacy = Self.legacyKeyedIdentity(remoteURL: remoteURL, mediaKey: mediaKey)
    else { return nil }
    return adoptLegacyKeyed(
      legacyIdentity: legacy,
      identity: Self.identity(remoteURL: remoteURL, mediaKey: mediaKey),
      kind: kind)
  }

  /// One probe per session and key: a miss is remembered so scrolling never re-stats the slot.
  private func adoptLegacyKeyed(
    legacyIdentity: String, identity: String, kind: VibeMediaKind
  ) -> URL? {
    lock.lock()
    let firstProbe = legacyProbedKeys.insert(kind.rawValue + ":" + legacyIdentity).inserted
    lock.unlock()
    guard firstProbe,
      let candidate = legacyKeyedCandidateURLs(legacyIdentity: legacyIdentity, kind: kind).first
    else { return nil }
    let source: URL
    if kind.preservesDisplayName {
      guard let file = Self.firstRegularFile(in: candidate) else { return nil }
      source = file
    } else {
      source = candidate
    }
    guard
      let adopted = adopt(
        fileAt: source, for: identity, kind: kind, displayName: source.lastPathComponent,
        move: true)
    else { return nil }
    if kind.preservesDisplayName {
      try? FileManager.default.removeItem(at: candidate)
    }
    let legacySlot = slotName(for: legacyIdentity)
    lock.lock()
    indexByKind[kind]?.removeValue(forKey: legacySlot)
    promisedByKind[kind]?.removeValue(forKey: legacySlot)
    lock.unlock()
    VibeLog.info(
      "vault-legacy-hit", category: "media",
      metadata: [
        "kind": kind.rawValue,
        "identity": identity,
        "file": adopted.lastPathComponent,
      ])
    return adopted
  }

  // MARK: - Writing

  /// Where a fresh download for this identity belongs. For a name-preserving kind the slot is
  /// cleared first, so one attachment never keeps two files under two names.
  func destinationURL(
    for identity: String, kind: VibeMediaKind, fileExtension: String?, displayName: String?
  ) -> URL {
    let ext = Self.sanitizedExtension(fileExtension)
    guard kind.preservesDisplayName else {
      let name = slotName(for: identity) + (ext.isEmpty ? "" : "." + ext)
      let url = directory(for: kind).appendingPathComponent(name, isDirectory: false)
      promise(url, kind: kind, identity: identity)
      return url
    }
    let slot = slotDirectory(for: identity, kind: kind)
    if let stale = try? FileManager.default.contentsOfDirectory(
      at: slot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    {
      for url in stale { try? FileManager.default.removeItem(at: url) }
    }
    let base = Self.sanitizedBaseName(displayName, fallback: slotName(for: identity))
    let url = slot.appendingPathComponent(base + (ext.isEmpty ? "" : "." + ext), isDirectory: false)
    promise(url, kind: kind, identity: identity)
    return url
  }

  private func promise(_ url: URL, kind: VibeMediaKind, identity: String) {
    let slot = slotName(for: identity)
    lock.lock()
    promisedByKind[kind, default: [:]][slot] = url
    lock.unlock()
  }

  @discardableResult
  func store(
    _ data: Data, for identity: String, kind: VibeMediaKind, fileExtension: String? = nil,
    displayName: String? = nil
  ) -> URL? {
    let destination = destinationURL(
      for: identity, kind: kind, fileExtension: fileExtension, displayName: displayName)
    do {
      try data.write(to: destination, options: [.atomic])
    } catch {
      return nil
    }
    recordInIndex(destination, kind: kind, identity: identity)
    noteFetchSucceeded(identity)
    return destination
  }

  /// Takes a file the app already has — a finished download in a temp location, or the user's
  /// own upload — and gives it the vault address, so the sender never re-downloads media it
  /// sent and a legacy layout is carried forward instead of re-fetched.
  @discardableResult
  func adopt(
    fileAt source: URL, for identity: String, kind: VibeMediaKind, displayName: String? = nil,
    move: Bool
  ) -> URL? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: source.path) else { return nil }
    let ext = source.pathExtension.isEmpty ? nil : source.pathExtension
    let destination = destinationURL(
      for: identity, kind: kind, fileExtension: ext,
      displayName: displayName ?? source.lastPathComponent)
    if source.standardizedFileURL == destination.standardizedFileURL {
      recordInIndex(destination, kind: kind, identity: identity)
      return destination
    }
    try? fm.removeItem(at: destination)
    do {
      if move {
        try fm.moveItem(at: source, to: destination)
      } else {
        try fm.copyItem(at: source, to: destination)
      }
    } catch {
      // A move can fail across volumes; a copy is always acceptable, losing the file is not.
      guard move, (try? fm.copyItem(at: source, to: destination)) != nil else { return nil }
    }
    recordInIndex(destination, kind: kind, identity: identity)
    noteFetchSucceeded(identity)
    return destination
  }

  /// Durable file for a just-picked photo/video. Never tmp — iOS deletes tmp between chat opens.
  func persistOutgoingPick(data: Data, fileExtension: String) -> URL? {
    let ext = Self.sanitizedExtension(fileExtension)
    let isVideo = ["mp4", "mov", "m4v", "webm"].contains(ext)
    return store(
      data,
      for: "outgoing:\(UUID().uuidString)",
      kind: isVideo ? .document : .image,
      fileExtension: ext.isEmpty ? "jpg" : ext,
      displayName: isVideo ? "video" : "photo")
  }

  /// Moves a temp export into the vault so the sender's file survives tmp eviction.
  func persistOutgoingPick(fileAt source: URL, move: Bool) -> URL? {
    let ext = source.pathExtension.lowercased()
    let isVideo = ["mp4", "mov", "m4v", "webm"].contains(ext)
    return adopt(
      fileAt: source,
      for: "outgoing:\(UUID().uuidString)",
      kind: isVideo ? .document : .image,
      displayName: source.lastPathComponent,
      move: move)
  }

  /// Drops a file the app can prove is unusable (truncated, or an error page saved as media).
  /// This is the ONLY automatic removal in the vault, and it exists so a poisoned byte range
  /// cannot wedge a row forever. A fetch that merely failed must not come here.
  func forget(_ identity: String, kind: VibeMediaKind) {
    if let url = index(for: kind)[slotName(for: identity)] {
      try? FileManager.default.removeItem(at: url)
    }
    if kind.preservesDisplayName {
      try? FileManager.default.removeItem(
        at: slotDirectory(for: identity, kind: kind, create: false))
    }
    dropFromIndex(kind: kind, identity: identity)
    lock.lock()
    promisedByKind[kind]?.removeValue(forKey: slotName(for: identity))
    lock.unlock()
  }

  // MARK: - Availability memo

  /// True when the app has stopped fetching this on its own: the origin gave a definitive
  /// non-2xx, or the transfer failed `maxFetchAttempts` times. Without this, every visible row
  /// re-armed its download on every scroll pass and a dead URL was requested dozens of times a
  /// minute while its cell sat in a "downloading" state it could never leave.
  ///
  /// In memory only, deliberately: a fresh launch is allowed one more try, because an outage is
  /// not a verdict. And it never implies deletion — a file already in the vault stays.
  func isUnavailable(_ identity: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return unavailableIdentities.contains(identity)
  }

  /// Records a failed attempt. Returns true when the app should stop asking on its own.
  @discardableResult
  func noteFetchFailed(_ identity: String, httpStatus: Int?) -> Bool {
    let originRefused = httpStatus.map { !(200...299).contains($0) } ?? false
    lock.lock()
    let attempts = (failureCountByIdentity[identity] ?? 0) + 1
    failureCountByIdentity[identity] = attempts
    let giveUp = originRefused || attempts >= Self.maxFetchAttempts
    if giveUp { unavailableIdentities.insert(identity) }
    lock.unlock()
    return giveUp
  }

  func noteFetchSucceeded(_ identity: String) {
    lock.lock()
    failureCountByIdentity.removeValue(forKey: identity)
    unavailableIdentities.remove(identity)
    lock.unlock()
  }

  /// The user asked for this row. Asking is always allowed, whatever the memo says.
  func allowRetry(_ identity: String) {
    noteFetchSucceeded(identity)
  }

  // MARK: - Catalog

  /// Every file the vault holds for a kind, including the pre-vault directories, so one listing
  /// answers both the Settings cache screen and a "files in this app" view.
  func entries(for kind: VibeMediaKind) -> [Entry] {
    var out: [Entry] = []
    let keys: [URLResourceKey] = [
      .fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isDirectoryKey,
    ]
    for directory in [directory(for: kind)] + externalDirectories(for: kind) {
      guard
        let walker = FileManager.default.enumerator(
          at: directory, includingPropertiesForKeys: keys,
          options: [.skipsHiddenFiles, .skipsPackageDescendants])
      else { continue }
      for case let url as URL in walker {
        let values = try? url.resourceValues(forKeys: Set(keys))
        guard values?.isRegularFile == true else { continue }
        out.append(
          Entry(
            url: url,
            kind: kind,
            identity: url.deletingPathExtension().lastPathComponent,
            displayName: url.lastPathComponent,
            byteSize: Int64(values?.fileSize ?? 0),
            modifiedAt: values?.contentModificationDate ?? .distantPast
          ))
      }
    }
    return out
  }

  func usage(for kind: VibeMediaKind) -> Usage {
    var usage = Usage()
    for entry in entries(for: kind) {
      usage.fileCount += 1
      usage.byteSize += entry.byteSize
    }
    return usage
  }

  func usage() -> [VibeMediaKind: Usage] {
    var out: [VibeMediaKind: Usage] = [:]
    for kind in VibeMediaKind.allCases { out[kind] = usage(for: kind) }
    return out
  }

  /// The user clearing space — the only sanctioned way a downloaded file leaves this device.
  /// Self-healing: every read path re-checks the vault and re-fetches on a miss.
  func clear(kinds: [VibeMediaKind]) {
    let fm = FileManager.default
    for kind in kinds {
      for entry in entries(for: kind) { try? fm.removeItem(at: entry.url) }
      // Slot kinds leave behind empty directories; drop them so the index rebuilds clean.
      if kind.preservesDisplayName,
        let items = try? fm.contentsOfDirectory(
          at: directory(for: kind), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
      {
        for item in items where item.hasDirectoryPath { try? fm.removeItem(at: item) }
      }
      lock.lock()
      indexByKind[kind] = nil
      promisedByKind[kind] = nil
      lock.unlock()
    }
  }

  /// An explicit, user-pressed sweep of files untouched for a while. Nothing calls this on a
  /// timer, and nothing should: "downloaded once" means kept until the user says otherwise.
  func clearEntries(olderThan cutoff: Date, kinds: [VibeMediaKind]) {
    for kind in kinds {
      for entry in entries(for: kind) where entry.modifiedAt < cutoff {
        try? FileManager.default.removeItem(at: entry.url)
      }
      lock.lock()
      indexByKind[kind] = nil
      lock.unlock()
    }
  }

  // MARK: - Naming

  private static func sanitizedExtension(_ value: String?) -> String {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      !value.isEmpty
    else { return "" }
    let cleaned = value.replacingOccurrences(
      of: "[^a-z0-9]+", with: "", options: .regularExpression)
    return cleaned.count <= 8 ? cleaned : ""
  }

  private static func sanitizedBaseName(_ value: String?, fallback: String) -> String {
    let raw = (value as NSString?)?.deletingPathExtension ?? ""
    let cleaned = raw.replacingOccurrences(
      of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
    let trimmed = String(cleaned.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    return trimmed.isEmpty ? fallback : trimmed
  }
}

/// Once-per-key media loss/reload logs so a later tmp-evict or vault miss is visible.
enum ChatMediaWatchdog {
  private static let lock = NSLock()
  private static var logged = Set<String>()

  static func once(key: String, _ message: String) {
    lock.lock()
    let inserted = logged.insert(key).inserted
    lock.unlock()
    guard inserted else { return }
    NSLog("[MediaWatchdog] %@", message)
  }
}
