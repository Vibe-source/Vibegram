import AVFoundation
import Foundation

extension Notification.Name {
  static let nativeMusicPlayerStateDidChange = Notification.Name(
    "NativeMusicPlayerStateDidChange")
}

final class NativeMusicPlayerEngine: NSObject {
  static let shared = NativeMusicPlayerEngine()

  private let store = NativeMusicPlayerStore.shared
  private let authHeadersProvider = NativeMusicPlayerAuthHeadersProvider()
  private lazy var downloadSession: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 120
    configuration.timeoutIntervalForResource = 600
    return URLSession(configuration: configuration)
  }()

  private var queueTrackIds: [String] = []
  private var currentTrackId: String?
  private var isPlaying = false
  private var isExpanded = false
  private var playbackRate: Double = 1.0
  private var queueOrderMode: NativeMusicPlayerQueueOrderMode = .forward
  private var isRepeatEnabled = false
  private var currentPositionMs: Double = 0.0
  private var currentDurationMs: Double = 0.0
  private var currentSourceURLKey: String?
  private var randomizedQueueTrackIds: [String] = []

  private var player: AVPlayer?
  private var playerItemStatusObservation: NSKeyValueObservation?
  private var playerTimeObserver: Any?
  private var playbackEndObserver: NSObjectProtocol?

  private var downloadTasks: [String: URLSessionDownloadTask] = [:]
  private var downloadObservations: [String: NSKeyValueObservation] = [:]
  private var pendingDownloadCompletions: [String: [([String: Any]) -> Void]] = [:]

  private override init() {
    super.init()
    publishState()
  }

  deinit {
    cleanupPlayer()
  }

  func getStatePayload() -> [String: Any] {
    let currentTrackPayload = currentTrack?.toPayload()
    let queuePayload = orderedQueueTrackIds().compactMap { store.getTrack(trackId: $0)?.toPayload() }
    return [
      "currentTrack": currentTrackPayload ?? NSNull(),
      "queue": queuePayload,
      "library": store.libraryTracksPayload(),
      "isPlaying": isPlaying,
      "isExpanded": isExpanded,
      "progress": currentPositionMs,
      "duration": currentDurationMs,
      "playbackRate": playbackRate,
      "queueOrderMode": queueOrderMode.rawValue,
      "isRepeatEnabled": isRepeatEnabled,
      "tracks": store.allTracksPayload(),
      "downloadingTracks": store.downloadingTracksPayload(),
    ]
  }

  func setQueue(_ rawTracks: [[String: Any]]) {
    DispatchQueue.main.async {
      let nextIds = rawTracks.compactMap { payload -> String? in
        guard let track = self.store.cacheTrack(payload: payload) else { return nil }
        return track.trackId
      }
      self.queueTrackIds = Self.deduplicated(ids: nextIds)
      if let currentTrackId = self.currentTrackId, !self.queueTrackIds.contains(currentTrackId) {
        self.queueTrackIds.insert(currentTrackId, at: 0)
      }
      self.syncRandomizedQueueTrackIds(anchorTrackId: self.currentTrackId, regenerate: false)
      self.publishState()
    }
  }

  func setTrack(_ payload: [String: Any]) {
    DispatchQueue.main.async {
      guard let track = self.store.cacheTrack(payload: payload) else { return }
      self.ensureTrackInQueue(track.trackId)
      let isSameTrack = self.currentTrackId == track.trackId
      self.currentTrackId = track.trackId
      self.isPlaying = true
      if self.queueOrderMode == .random, !isSameTrack {
        self.syncRandomizedQueueTrackIds(anchorTrackId: track.trackId, regenerate: true)
      }
      if isSameTrack, self.currentSourceURLKey != nil {
        self.playCurrentIfReady()
        self.publishState()
        return
      }
      self.preparePlaybackForCurrentTrack()
    }
  }

  func setIsPlaying(_ value: Bool) {
    DispatchQueue.main.async {
      self.isPlaying = value
      if value {
        self.playCurrentIfReady()
      } else {
        self.player?.pause()
      }
      self.publishState()
    }
  }

  func setIsExpanded(_ value: Bool) {
    DispatchQueue.main.async {
      guard self.isExpanded != value else { return }
      self.isExpanded = value
      self.publishState()
    }
  }

  func setPlaybackRate(_ value: Double) {
    DispatchQueue.main.async {
      let normalized = max(0.5, min(3.0, value))
      self.playbackRate = normalized
      if self.isPlaying {
        self.player?.rate = Float(normalized)
      }
      self.publishState()
    }
  }

  /// Cycles 1× → 1.5× → 2× → 1× (mirrors `VoiceBubblePlaybackCoordinator.cyclePlaybackRate`).
  func cyclePlaybackRate() {
    DispatchQueue.main.async {
      let rates: [Double] = [1.0, 1.5, 2.0]
      let index = rates.firstIndex(where: { abs($0 - self.playbackRate) < 0.05 }) ?? 0
      let nextRate = rates[(index + 1) % rates.count]
      self.playbackRate = nextRate
      if self.isPlaying {
        self.player?.rate = Float(nextRate)
      }
      self.publishState()
    }
  }

  func setQueueOrderMode(_ value: NativeMusicPlayerQueueOrderMode) {
    DispatchQueue.main.async {
      guard self.queueOrderMode != value else { return }
      self.queueOrderMode = value
      self.syncRandomizedQueueTrackIds(
        anchorTrackId: self.currentTrackId,
        regenerate: value == .random
      )
      self.publishState()
    }
  }

  func toggleQueueOrderMode() {
    setQueueOrderMode(queueOrderMode.next())
  }

  func setRepeatEnabled(_ value: Bool) {
    DispatchQueue.main.async {
      guard self.isRepeatEnabled != value else { return }
      self.isRepeatEnabled = value
      self.publishState()
    }
  }

  func toggleRepeatEnabled() {
    setRepeatEnabled(!isRepeatEnabled)
  }

  func playNext() {
    DispatchQueue.main.async {
      guard let nextId = self.adjacentTrackId(step: 1, wraps: self.isRepeatEnabled) else { return }
      guard let track = self.store.getTrack(trackId: nextId) else { return }
      self.currentTrackId = track.trackId
      self.isPlaying = true
      self.preparePlaybackForCurrentTrack()
    }
  }

  func playPrev() {
    DispatchQueue.main.async {
      guard let prevId = self.adjacentTrackId(step: -1, wraps: self.isRepeatEnabled) else { return }
      guard let track = self.store.getTrack(trackId: prevId) else { return }
      self.currentTrackId = track.trackId
      self.isPlaying = true
      self.preparePlaybackForCurrentTrack()
    }
  }

  func seek(toMilliseconds milliseconds: Double) {
    DispatchQueue.main.async {
      guard let player = self.player else { return }
      let clamped = max(0.0, min(milliseconds, max(self.currentDurationMs, milliseconds)))
      let seconds = clamped / 1000.0
      let time = CMTime(seconds: seconds, preferredTimescale: 600)
      player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
        self.currentPositionMs = clamped
        self.publishState()
      }
    }
  }

  func reset() {
    DispatchQueue.main.async {
      self.isPlaying = false
      self.isExpanded = false
      self.currentTrackId = nil
      self.queueTrackIds = []
      self.randomizedQueueTrackIds = []
      self.queueOrderMode = .forward
      self.isRepeatEnabled = false
      self.currentPositionMs = 0.0
      self.currentDurationMs = 0.0
      self.currentSourceURLKey = nil
      self.cleanupPlayer()
      self.publishState()
    }
  }

  func cacheTrack(_ payload: [String: Any]) -> [String: Any]? {
    return readOnMain {
      let result = self.store.cacheTrack(payload: payload)?.toPayload()
      self.publishState()
      return result
    }
  }

  func getTrack(_ trackId: String) -> [String: Any]? {
    readOnMain {
      self.store.getTrack(trackId: trackId)?.toPayload()
    }
  }

  func removeTrack(_ trackId: String) {
    DispatchQueue.main.async {
      self.cancelDownload(for: trackId)
      if self.currentTrackId == trackId {
        self.reset()
      } else {
        self.store.removeTrack(trackId: trackId)
        self.queueTrackIds.removeAll { $0 == trackId }
        self.syncRandomizedQueueTrackIds(anchorTrackId: self.currentTrackId, regenerate: false)
        self.publishState()
      }
    }
  }

  func downloadTrack(_ payload: [String: Any], completion: (([String: Any]) -> Void)? = nil) {
    DispatchQueue.main.async {
      guard let track = self.store.cacheTrack(payload: payload) else {
        completion?(["success": false, "error": "invalid_track"])
        return
      }

      if let localURL = self.store.resolvedCachedFileURL(for: track) {
        completion?([
          "success": true,
          "localUri": localURL.absoluteString,
          "track": self.store.getTrack(trackId: track.trackId)?.toPayload() ?? NSNull(),
        ])
        self.publishState()
        return
      }

      if let existingTask = self.downloadTasks[track.trackId] {
        if let completion {
          self.pendingDownloadCompletions[track.trackId, default: []].append(completion)
        }
        if existingTask.state == .running {
          self.publishState()
          return
        }
      }

      guard let remoteURL = self.resolveRemoteDownloadURL(for: track) else {
        completion?(["success": false, "error": "missing_remote_url"])
        return
      }

      if let completion {
        self.pendingDownloadCompletions[track.trackId, default: []].append(completion)
      }
      self.startDownload(track: track, remoteURL: remoteURL)
    }
  }

  var currentTrack: NativeMusicPlayerTrack? {
    guard let currentTrackId else { return nil }
    return store.getTrack(trackId: currentTrackId)
  }

  func selectTrack(_ trackId: String) {
    DispatchQueue.main.async {
      guard let track = self.store.getTrack(trackId: trackId) else { return }
      self.ensureTrackInQueue(track.trackId)
      self.currentTrackId = track.trackId
      if self.queueOrderMode == .random {
        self.syncRandomizedQueueTrackIds(anchorTrackId: track.trackId, regenerate: true)
      }
      self.currentPositionMs = 0.0
      self.currentDurationMs = (track.durationSeconds ?? 0.0) * 1000.0
      // Stream immediately when needed; auto-download / prefetch still run inside prepare.
      // Waiting for cache completion would regress backend-stream-only tracks.
      self.isPlaying = true
      self.preparePlaybackForCurrentTrack()
    }
  }

  private func ensureTrackInQueue(_ trackId: String) {
    if queueTrackIds.contains(trackId) { return }
    queueTrackIds.insert(trackId, at: 0)
    syncRandomizedQueueTrackIds(anchorTrackId: currentTrackId ?? trackId, regenerate: queueOrderMode == .random)
  }

  private func preparePlaybackForCurrentTrack() {
    guard let track = currentTrack else {
      cleanupPlayer()
      publishState()
      return
    }

    guard let resolvedURL = resolvePlaybackURL(for: track) else {
      isPlaying = false
      publishState()
      return
    }

    let sourceKey = resolvedURL.absoluteString
    if currentSourceURLKey == sourceKey, player != nil {
      playCurrentIfReady()
      publishState()
      return
    }

    currentSourceURLKey = sourceKey
    currentPositionMs = 0.0
    currentDurationMs = (track.durationSeconds ?? 0.0) * 1000.0
    configureAudioSessionIfNeeded()
    cleanupPlayer()

    // Backend /api/music/stream URLs sit behind api auth — AVPlayer can't attach the
    // bearer, so resolve them to the public CDN/direct URL first (memoized per session).
    if let videoId = ChatMusicStreamResolver.videoId(fromBackendStreamURL: resolvedURL) {
      if let publicURL = ChatMusicStreamResolver.shared.cachedResolvedURL(forVideoId: videoId) {
        attachPlayer(url: publicURL, track: track)
        return
      }
      publishState()
      ChatMusicStreamResolver.shared.resolve(
        videoId: videoId,
        headers: authHeadersProvider.headers()
      ) { [weak self] publicURL in
        guard let self,
          self.currentTrackId == track.trackId,
          self.currentSourceURLKey == sourceKey
        else { return }
        self.attachPlayer(url: publicURL ?? resolvedURL, track: track)
      }
      return
    }

    attachPlayer(url: resolvedURL, track: track)
  }

  private func attachPlayer(url resolvedURL: URL, track: NativeMusicPlayerTrack) {
    let item = AVPlayerItem(url: resolvedURL)
    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = true
    self.player = player

    playerItemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
      guard let self else { return }
      DispatchQueue.main.async {
        switch item.status {
        case .readyToPlay:
          if item.duration.seconds.isFinite && item.duration.seconds > 0 {
            self.currentDurationMs = item.duration.seconds * 1000.0
          }
          self.playCurrentIfReady()
          self.publishState()
        case .failed:
          self.isPlaying = false
          self.publishState()
        default:
          break
        }
      }
    }

    playerTimeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
      queue: .main
    ) { [weak self] time in
      guard let self else { return }
      self.currentPositionMs = max(0.0, time.seconds * 1000.0)
      if let duration = self.player?.currentItem?.duration,
        duration.seconds.isFinite,
        duration.seconds > 0
      {
        self.currentDurationMs = duration.seconds * 1000.0
      }
      self.publishState()
    }

    playbackEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      self?.handlePlaybackDidFinish()
    }

    if shouldAutoDownload(track) {
      if let remoteURL = resolveRemoteDownloadURL(for: track) {
        startDownload(track: track, remoteURL: remoteURL)
      }
    }

    prefetchUpcomingTrackIfNeeded()

    publishState()
  }

  private func playCurrentIfReady() {
    guard isPlaying else {
      player?.pause()
      return
    }
    guard let player else { return }
    let status = player.currentItem?.status ?? .unknown
    guard status == .readyToPlay else { return }
    if player.currentItem?.currentTime() == player.currentItem?.duration {
      player.seek(to: .zero)
    }
    player.playImmediately(atRate: Float(playbackRate))
    if let currentTrackId {
      _ = store.recordPlay(trackId: currentTrackId)
    }
  }

  private func handlePlaybackDidFinish() {
    currentPositionMs = currentDurationMs
    let shouldResetOnly = {
      guard let track = currentTrack else { return false }
      return track.source == "chat-voice" || track.title == "Voice Message"
    }()

    if shouldResetOnly {
      isPlaying = false
      player?.seek(to: .zero)
      currentPositionMs = 0.0
      publishState()
      return
    }

    if let nextId = adjacentTrackId(step: 1, wraps: isRepeatEnabled) {
      self.currentTrackId = nextId
      isPlaying = true
      preparePlaybackForCurrentTrack()
      return
    }

    isPlaying = false
    publishState()
  }

  private func cleanupPlayer() {
    if let timeObserver = playerTimeObserver {
      player?.removeTimeObserver(timeObserver)
      playerTimeObserver = nil
    }
    if let playbackEndObserver {
      NotificationCenter.default.removeObserver(playbackEndObserver)
      self.playbackEndObserver = nil
    }
    playerItemStatusObservation?.invalidate()
    playerItemStatusObservation = nil
    player?.pause()
    player = nil
  }

  private func publishState() {
    let payload = getStatePayload()
    NotificationCenter.default.post(
      name: .nativeMusicPlayerStateDidChange,
      object: self,
      userInfo: ["payload": payload]
    )
  }

  private func shouldAutoDownload(_ track: NativeMusicPlayerTrack) -> Bool {
    if track.source == "chat-voice" { return false }
    if store.resolvedCachedFileURL(for: track) != nil { return false }
    if downloadTasks[track.trackId] != nil { return false }
    return resolveRemoteDownloadURL(for: track) != nil
  }

  private func prefetchUpcomingTrackIfNeeded() {
    guard let nextId = adjacentTrackId(step: 1, wraps: false) else { return }
    guard let nextTrack = store.getTrack(trackId: nextId), shouldAutoDownload(nextTrack) else { return }
    guard let remoteURL = resolveRemoteDownloadURL(for: nextTrack) else { return }
    startDownload(track: nextTrack, remoteURL: remoteURL)
  }

  private func orderedQueueTrackIds() -> [String] {
    switch queueOrderMode {
    case .forward:
      return queueTrackIds
    case .reverse:
      return Array(queueTrackIds.reversed())
    case .random:
      syncRandomizedQueueTrackIds(anchorTrackId: currentTrackId, regenerate: false)
      return randomizedQueueTrackIds
    }
  }

  private func adjacentTrackId(step: Int, wraps: Bool) -> String? {
    guard step != 0 else { return nil }
    guard let currentTrackId else { return nil }
    let orderedIds = orderedQueueTrackIds()
    guard !orderedIds.isEmpty else { return nil }
    guard let currentIndex = orderedIds.firstIndex(of: currentTrackId) else { return nil }

    let nextIndex = currentIndex + step
    if orderedIds.indices.contains(nextIndex) {
      return orderedIds[nextIndex]
    }
    guard wraps else { return nil }
    return step > 0 ? orderedIds.first : orderedIds.last
  }

  private func syncRandomizedQueueTrackIds(anchorTrackId: String?, regenerate: Bool) {
    let baseIds = Self.deduplicated(ids: queueTrackIds)
    let expected = Set(baseIds)
    let current = Set(randomizedQueueTrackIds)
    let needsRefresh =
      regenerate
      || randomizedQueueTrackIds.count != baseIds.count
      || current != expected

    guard needsRefresh else { return }

    var shuffledIds = baseIds
    if let anchorTrackId,
      let anchorIndex = shuffledIds.firstIndex(of: anchorTrackId)
    {
      shuffledIds.remove(at: anchorIndex)
      shuffledIds.shuffle()
      shuffledIds.insert(anchorTrackId, at: 0)
    } else {
      shuffledIds.shuffle()
    }
    randomizedQueueTrackIds = shuffledIds
  }

  private func resolvePlaybackURL(for track: NativeMusicPlayerTrack) -> URL? {
    if let localURL = store.resolvedCachedFileURL(for: track) {
      return localURL
    }
    if let localURI = track.localURI, let fileURL = Self.resolveFileURL(from: localURI),
      FileManager.default.fileExists(atPath: fileURL.path)
    {
      return fileURL
    }
    // Prefer direct preview/stream URLs, then backend /api/music/stream/:videoId.
    // Both are also eligible for download + upcoming prefetch via resolveRemoteDownloadURL.
    if let remoteURL = resolveRemoteDownloadURL(for: track) {
      return remoteURL
    }
    return nil
  }

  private func resolveRemoteDownloadURL(for track: NativeMusicPlayerTrack) -> URL? {
    if let previewURL = resolveNetworkURL(from: track.previewURL) {
      return previewURL
    }
    if let streamURL = resolveNetworkURL(from: track.streamURL) {
      return streamURL
    }
    // Backend proxy is cacheable (auth headers applied in startDownload), not stream-only.
    guard let backendURL = resolveBackendStreamURL(for: track) else { return nil }
    // Prefer the already-resolved public URL: it has a real Content-Length for byte
    // progress and survives the backend cache-fill failing (where /stream 500s).
    if let videoId = ChatMusicStreamResolver.videoId(fromBackendStreamURL: backendURL),
      let publicURL = ChatMusicStreamResolver.shared.cachedResolvedURL(forVideoId: videoId)
    {
      return publicURL
    }
    return backendURL
  }

  private func resolveBackendStreamURL(for track: NativeMusicPlayerTrack) -> URL? {
    // Skip voice notes — they use local files and must not hit the music proxy.
    if track.source == "chat-voice" { return nil }
    let candidate = track.videoId ?? track.id
    guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    // Message-id shaped track ids (UUIDs) are not YouTube video ids.
    if value.count > 20, value.contains("-") { return nil }
    return URL(
      string: "https://api.vibegram.io/api/music/stream/\(value)")
  }

  private func resolveNetworkURL(from value: String?) -> URL? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    guard !trimmed.hasPrefix("file://"), !trimmed.hasPrefix("/") else { return nil }
    return URL(string: trimmed)
  }

  private func startDownload(track: NativeMusicPlayerTrack, remoteURL: URL) {
    if downloadTasks[track.trackId] != nil { return }
    let destinationURL = store.cacheDestinationURL(for: track, remoteURL: remoteURL)
    // Every re-download of a track the device already had went unexplained because nothing
    // recorded WHY the store thought it had no file. `localURI` is what it believed it had.
    NSLog(
      "[MusicCache] DOWNLOAD trackId=%@ title=%@ remote=%@ localURI=%@",
      track.trackId, track.title, remoteURL.absoluteString, track.localURI ?? "nil")
    var request = URLRequest(url: remoteURL)
    let host = remoteURL.host?.lowercased() ?? ""
    let isOwnHost = host == "vibegram.io" || host.hasSuffix(".vibegram.io")
    for (key, value) in authHeadersProvider.headers() {
      // Never leak the API bearer to third-party/CDN hosts (Supabase, direct sources).
      if key == "Authorization" && !isOwnHost { continue }
      request.setValue(value, forHTTPHeaderField: key)
    }

    let task = downloadSession.downloadTask(with: request) { [weak self] tempURL, response, error in
      guard let self else { return }
      DispatchQueue.main.async {
        self.finishDownload(
          trackId: track.trackId,
          remoteURL: remoteURL,
          tempURL: tempURL,
          destinationURL: destinationURL,
          response: response,
          error: error
        )
      }
    }
    downloadTasks[track.trackId] = task
    store.setDownloadProgress(trackId: track.trackId, progress: 0.0)
    downloadObservations[track.trackId] = task.progress.observe(\.fractionCompleted, options: [.new]) {
      [weak self] progress, _ in
      guard let self else { return }
      DispatchQueue.main.async {
        self.store.setDownloadProgress(trackId: track.trackId, progress: progress.fractionCompleted)
        self.publishState()
      }
    }
    task.resume()
    publishState()
  }

  private func finishDownload(
    trackId: String,
    remoteURL: URL,
    tempURL: URL?,
    destinationURL: URL,
    response: URLResponse?,
    error: Error?
  ) {
    defer {
      downloadTasks[trackId] = nil
      downloadObservations[trackId]?.invalidate()
      downloadObservations[trackId] = nil
    }

    let statusCode = (response as? HTTPURLResponse)?.statusCode
    let httpFailed = statusCode.map { !((200..<300).contains($0)) } ?? false

    if let error {
      store.setDownloadProgress(trackId: trackId, progress: nil)
      resolvePendingDownloadCompletions(trackId: trackId, payload: [
        "success": false,
        "error": error.localizedDescription,
      ])
      // Keep streaming from the remote URL if this track is currently active.
      if currentTrackId == trackId, isPlaying, player == nil || currentSourceURLKey != remoteURL.absoluteString {
        preparePlaybackForCurrentTrack()
      } else {
        publishState()
      }
      return
    }

    if httpFailed {
      store.setDownloadProgress(trackId: trackId, progress: nil)
      resolvePendingDownloadCompletions(trackId: trackId, payload: [
        "success": false,
        "error": "http_\(statusCode ?? 0)",
        "statusCode": statusCode as Any,
      ])
      if currentTrackId == trackId, isPlaying {
        preparePlaybackForCurrentTrack()
      } else {
        publishState()
      }
      return
    }

    guard let tempURL else {
      store.setDownloadProgress(trackId: trackId, progress: nil)
      resolvePendingDownloadCompletions(trackId: trackId, payload: [
        "success": false,
        "error": "missing_temp_file",
      ])
      if currentTrackId == trackId, isPlaying {
        preparePlaybackForCurrentTrack()
      } else {
        publishState()
      }
      return
    }

    do {
      try? FileManager.default.removeItem(at: destinationURL)
      try FileManager.default.moveItem(at: tempURL, to: destinationURL)
      let updatedTrack = store.updateLocalURI(trackId: trackId, localURI: destinationURL.absoluteString)
      store.setDownloadProgress(trackId: trackId, progress: nil)
      resolvePendingDownloadCompletions(trackId: trackId, payload: [
        "success": true,
        "localUri": destinationURL.absoluteString,
        "remoteUrl": remoteURL.absoluteString,
        "statusCode": statusCode as Any,
        "track": updatedTrack?.toPayload() ?? NSNull(),
      ])
      // Prefer the newly cached file for the active track without interrupting mid-play.
      if currentTrackId == trackId,
        let track = store.getTrack(trackId: trackId) ?? updatedTrack,
        let localURL = store.resolvedCachedFileURL(for: track),
        currentSourceURLKey != localURL.absoluteString,
        !isPlaying || player == nil
      {
        preparePlaybackForCurrentTrack()
      } else {
        publishState()
      }
    } catch {
      store.setDownloadProgress(trackId: trackId, progress: nil)
      resolvePendingDownloadCompletions(trackId: trackId, payload: [
        "success": false,
        "error": error.localizedDescription,
      ])
      if currentTrackId == trackId, isPlaying {
        preparePlaybackForCurrentTrack()
      } else {
        publishState()
      }
    }
  }

  private func resolvePendingDownloadCompletions(trackId: String, payload: [String: Any]) {
    let completions = pendingDownloadCompletions.removeValue(forKey: trackId) ?? []
    for completion in completions {
      completion(payload)
    }
  }

  private func cancelDownload(for trackId: String) {
    downloadTasks[trackId]?.cancel()
    downloadTasks[trackId] = nil
    downloadObservations[trackId]?.invalidate()
    downloadObservations[trackId] = nil
    pendingDownloadCompletions.removeValue(forKey: trackId)
    store.setDownloadProgress(trackId: trackId, progress: nil)
  }

  private func configureAudioSessionIfNeeded() {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      // Keep playback best-effort; UI state still updates.
    }
  }

  private func readOnMain<T>(_ block: () -> T) -> T {
    if Thread.isMainThread {
      return block()
    }
    return DispatchQueue.main.sync(execute: block)
  }

  private static func resolveFileURL(from value: String) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let url = URL(string: trimmed), url.isFileURL {
      return url
    }
    if trimmed.hasPrefix("/") {
      return URL(fileURLWithPath: trimmed)
    }
    return nil
  }

  private static func deduplicated(ids: [String]) -> [String] {
    var result: [String] = []
    var seen = Set<String>()
    for id in ids where !id.isEmpty {
      if seen.insert(id).inserted {
        result.append(id)
      }
    }
    return result
  }
}

/// Resolves a backend `/api/music/stream/:videoId` URL into the PUBLIC audio URL
/// (Supabase CDN or direct source) via the authed `/api/music/info/:videoId` endpoint.
/// AVPlayer cannot attach the API bearer, so streaming the backend URL directly 401s
/// (NSURLErrorDomain -1013); the info endpoint also falls back to a direct stream URL
/// when the server-side cache fill fails (where /stream would 500), and public URLs
/// carry a real Content-Length so download byte totals work. Resolved URLs are
/// memoized per videoId for the session (direct source URLs expire, so never persist).
final class ChatMusicStreamResolver {
  static let shared = ChatMusicStreamResolver()

  private let lock = NSLock()
  private var resolvedByVideoId: [String: URL] = [:]
  private var inFlight: [String: [(URL?) -> Void]] = [:]

  /// Non-nil only for our own backend's `/api/music/stream/{videoId}` URLs.
  static func videoId(fromBackendStreamURL url: URL) -> String? {
    guard !url.isFileURL, let host = url.host?.lowercased(),
      host == "vibegram.io" || host.hasSuffix(".vibegram.io")
    else { return nil }
    let parts = url.path.split(separator: "/").map(String.init)
    guard parts.count >= 4, parts[0] == "api", parts[1] == "music", parts[2] == "stream" else {
      return nil
    }
    let id = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
    return id.isEmpty ? nil : id
  }

  func cachedResolvedURL(forVideoId videoId: String) -> URL? {
    lock.lock()
    defer { lock.unlock() }
    return resolvedByVideoId[videoId]
  }

  /// Completion always fires on main. nil = resolution failed — the caller should
  /// fall back to streaming/downloading the backend URL so behaviour never regresses.
  func resolve(videoId: String, headers: [String: String], completion: @escaping (URL?) -> Void) {
    lock.lock()
    if let cached = resolvedByVideoId[videoId] {
      lock.unlock()
      DispatchQueue.main.async { completion(cached) }
      return
    }
    if inFlight[videoId] != nil {
      inFlight[videoId]?.append(completion)
      lock.unlock()
      return
    }
    inFlight[videoId] = [completion]
    lock.unlock()

    let encodedId =
      videoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? videoId
    // Prefer the session API base when available; fall back to production host.
    let base =
      ChatEngine.shared.authorizationHeaderForAPI() != nil
      ? (AppSessionConfig.current?.apiBaseURLString ?? "https://api.vibegram.io")
      : "https://api.vibegram.io"
    var root = base.trimmingCharacters(in: .whitespacesAndNewlines)
    while root.hasSuffix("/") { root.removeLast() }
    if !root.lowercased().hasSuffix("/api") { root += "/api" }
    guard let infoURL = URL(string: "\(root)/music/info/\(encodedId)") else {
      finish(videoId: videoId, url: nil)
      return
    }
    var request = URLRequest(url: infoURL)
    // On a cache miss the server downloads + uploads the track before answering
    // (up to ~2 min of yt-dlp) — give it room instead of timing out at 60s.
    request.timeoutInterval = 150
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
    let task = VibeHTTP.shared.dataTask(with: request) { [weak self] data, response, _ in
      guard let self else { return }
      var resolved: URL?
      if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
        let data,
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let raw = (object["stream_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !raw.isEmpty,
        let url = URL(string: raw), url.scheme?.lowercased().hasPrefix("http") == true
      {
        resolved = url
      }
      NSLog(
        "[MusicResolver] videoId=%@ resolved=%@",
        videoId,
        resolved?.host ?? "nil"
      )
      self.finish(videoId: videoId, url: resolved)
    }
    task.resume()
  }

  private func finish(videoId: String, url: URL?) {
    lock.lock()
    if let url { resolvedByVideoId[videoId] = url }
    let callbacks = inFlight.removeValue(forKey: videoId) ?? []
    lock.unlock()
    DispatchQueue.main.async {
      for callback in callbacks { callback(url) }
    }
  }
}

private final class NativeMusicPlayerAuthHeadersProvider {
  func headers() -> [String: String] {
    var values: [String: String] = ["ngrok-skip-browser-warning": "true"]
    guard let loginToken = currentLoginToken(), !loginToken.isEmpty else { return values }
    values["Authorization"] = "Bearer \(loginToken)"
    return values
  }

  private func currentLoginToken() -> String? {
    guard
      let authManagerClass = NSClassFromString("AuthManager") as? NSObject.Type,
      authManagerClass.responds(to: NSSelectorFromString("getInstance"))
    else {
      return nil
    }
    let managerSelector = NSSelectorFromString("getInstance")
    guard let unmanagedManager = authManagerClass.perform(managerSelector) else { return nil }
    guard let manager = unmanagedManager.takeUnretainedValue() as? NSObject else { return nil }
    let sessionSelector = NSSelectorFromString("getSession")
    guard manager.responds(to: sessionSelector),
      let unmanagedSession = manager.perform(sessionSelector)
    else {
      return nil
    }
    guard let session = unmanagedSession.takeUnretainedValue() as? NSObject else { return nil }
    return (session.value(forKey: "loginToken") as? String)
      ?? (session.value(forKey: "token") as? String)
  }
}
