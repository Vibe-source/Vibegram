import UIKit

/// Live computer session (agent-computer-v1 §3.2): creates it over HTTP, then rides
/// `computer:<agentId>` for frames/state and pushes `input` + `control` back.
@available(iOS 13.0, *)
final class VibeAgentComputerSession {

  struct Frame {
    let seq: Int
    let image: UIImage
    /// Remote viewport the frame was captured at — input maps against this, never the view.
    let viewport: CGSize
    let url: String
    let title: String
    let loading: Bool
    /// Every frame carries it in the shipped contract; absent leaves the last value alone.
    let control: String?
  }

  struct State {
    let url: String
    let title: String
    let loading: Bool
    let control: String
    let holder: String?
  }

  enum Failure: Error {
    case notConfigured
    case unknownAgent
    case http(Int)
    case malformed

    var isCapacity: Bool {
      if case .http(let code) = self { return code == 429 }
      return false
    }
  }

  // MARK: - Callbacks (always delivered on the main thread)

  var onFrame: ((Frame) -> Void)?
  var onState: ((State) -> Void)?
  var onEnded: ((String) -> Void)?
  var onLinkChanged: ((Bool) -> Void)?

  let agentId: String
  let sessionId: String
  let topic: String
  /// Asked for on join; the channel clamps 1–10 and echoes the real rate in the join reply.
  private(set) var fps: Int
  let requestedWidth: Int
  private(set) var control: String
  private(set) var holder: String?

  private let api: AppSessionConfig
  private var client: ChatPhoenixClient?
  private var joinRef: String?
  private var joined = false
  private var stopped = false

  private let decodeQueue = DispatchQueue(
    label: "vibe.agent.computer.decode", qos: .userInitiated)
  private let pendingLock = NSLock()
  private var pendingPayload: [String: Any]?
  private var decoding = false
  private var lastRenderedSeq = -1
  private var lastScrollSentAt: TimeInterval = 0

  private init(
    api: AppSessionConfig, agentId: String, sessionId: String, topic: String,
    fps: Int, width: Int, control: String, holder: String?
  ) {
    self.api = api
    self.agentId = agentId
    self.sessionId = sessionId
    self.topic = topic
    self.fps = fps
    self.requestedWidth = width
    self.control = control
    self.holder = holder
  }

  /// A session dropped without a `stop()` still has to be released server-side.
  deinit { stop() }

  // MARK: - Creation

  /// Resolves the agent, POSTs a session and hands back a client ready to `start()`.
  /// Fails (never falls back) so the caller can open the still-frame sheet instead.
  static func create(
    agentId explicitAgentId: String?,
    chatId: String?,
    completion: @escaping (Result<VibeAgentComputerSession, Failure>) -> Void
  ) {
    guard let api = AppSessionConfig.current else {
      DispatchQueue.main.async { completion(.failure(.notConfigured)) }
      return
    }
    resolveAgentId(explicit: explicitAgentId, chatId: chatId, api: api) { agentId in
      guard let agentId, !agentId.isEmpty else {
        DispatchQueue.main.async { completion(.failure(.unknownAgent)) }
        return
      }
      guard let url = apiURL(api: api, path: "/api/agents/\(escape(agentId))/computer/session")
      else {
        DispatchQueue.main.async { completion(.failure(.notConfigured)) }
        return
      }
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.timeoutInterval = 12
      request.setValue("Bearer \(api.authToken)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try? JSONSerialization.data(withJSONObject: [String: Any]())

      ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) { data, response, _ in
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let payload =
          data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        guard (200..<300).contains(status) else {
          DispatchQueue.main.async { completion(.failure(.http(status))) }
          return
        }
        guard let sessionId = normalized(payload["sessionId"] ?? payload["session_id"]) else {
          DispatchQueue.main.async { completion(.failure(.malformed)) }
          return
        }
        let session = VibeAgentComputerSession(
          api: api,
          agentId: agentId,
          sessionId: sessionId,
          topic: normalized(payload["topic"]) ?? "computer:\(agentId)",
          fps: intValue(payload["fps"]) ?? 3,
          width: intValue(payload["width"]) ?? 720,
          control: normalized(payload["control"]) ?? "agent",
          holder: normalized(payload["holder"])
        )
        DispatchQueue.main.async { completion(.success(session)) }
      }.resume()
    }
  }

  // MARK: - Channel

  /// Dials the computer channel and joins `topic` with this session id.
  func start() {
    guard !stopped, client == nil else { return }
    guard let socketURL = URL(string: api.socketURLString) else { return }
    let callbacks = ChatPhoenixClient.Callbacks(
      onOpen: { [weak self] in self?.handleSocketOpen() },
      onClose: { [weak self] _, _ in self?.handleLinkDrop() },
      onError: { [weak self] _ in self?.handleLinkDrop() },
      onEvent: { [weak self] frame in self?.handleFrame(frame) }
    )
    let next = ChatPhoenixClient(
      baseURL: socketURL, params: [:], authToken: api.authToken, callbacks: callbacks)
    client = next
    next.connect()
  }

  /// Leaves the channel, drops the socket and DELETEs the session. Idempotent, and the
  /// only exit — nothing may keep polling once the sheet is gone.
  func stop() {
    guard !stopped else { return }
    stopped = true
    teardownTransport()
    deleteSession()
    onFrame = nil
    onState = nil
    onEnded = nil
    onLinkChanged = nil
  }

  private func handleLinkDrop() {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.stopped else { return }
      self.joined = false
      self.onLinkChanged?(false)
    }
  }

  private func teardownTransport() {
    joined = false
    joinRef = nil
    if let client {
      client.leave(topic: topic)
      client.disconnect()
    }
    client = nil
    pendingLock.lock()
    pendingPayload = nil
    pendingLock.unlock()
  }

  private func deleteSession() {
    guard
      let url = Self.apiURL(
        api: api,
        path: "/api/agents/\(Self.escape(agentId))/computer/session/\(Self.escape(sessionId))")
    else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.timeoutInterval = 8
    request.setValue("Bearer \(api.authToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    ChatPhoenixClient.makePinnedURLSession().dataTask(with: request).resume()
  }

  private func handleSocketOpen() {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.stopped, let client = self.client else { return }
      self.joinRef = client.join(
        topic: self.topic, payload: ["sessionId": self.sessionId, "fps": self.fps])
    }
  }

  /// Arrives on the socket's delegate queue: only the image decode stays off-main, and
  /// every other event hops to main so the session's own state has a single owner.
  private func handleFrame(_ frame: ChatTransportFrame) {
    guard frame.topic == topic else { return }
    if frame.event == "frame" {
      enqueue(frame.payload)
      return
    }
    DispatchQueue.main.async { [weak self] in self?.handleControlEvent(frame) }
  }

  private func handleControlEvent(_ frame: ChatTransportFrame) {
    guard !stopped else { return }
    switch frame.event {
    case "phx_reply":
      guard let ref = frame.ref, ref == joinRef else { return }
      let ok = (frame.payload["status"] as? String)?.lowercased() == "ok"
      joined = ok
      if ok, let response = frame.payload["response"] as? [String: Any] {
        if let granted = Self.intValue(response["fps"]), granted > 0 { fps = granted }
        applyState(response, emit: true)
      }
      onLinkChanged?(ok)
    case "phx_close", "phx_error":
      joined = false
      onLinkChanged?(false)
    case "state":
      applyState(frame.payload, emit: true)
    case "session_ended":
      teardownTransport()
      onEnded?(Self.endedReason(frame.payload["reason"]))
    default:
      return
    }
  }

  /// Phase 1 ships exactly four reasons; anything else is reported as a plain stop.
  private static func endedReason(_ raw: Any?) -> String {
    let reason = (normalized(raw) ?? "").lowercased()
    return ["idle", "cap", "stopped", "error"].contains(reason) ? reason : "stopped"
  }

  @discardableResult
  private func applyState(_ payload: [String: Any], emit: Bool) -> State {
    let state = State(
      url: Self.normalized(payload["url"]) ?? "",
      title: Self.normalized(payload["title"]) ?? "",
      loading: (payload["loading"] as? Bool) ?? false,
      control: Self.normalized(payload["control"]) ?? control,
      holder: Self.normalized(payload["holder"])
    )
    control = state.control
    holder = state.holder
    if emit { onState?(state) }
    return state
  }

  // MARK: - Frame decode (off-main, newest only)

  /// Keeps only the newest undecoded frame: a backlog of stale viewports is worse than
  /// a skipped one, so anything arriving mid-decode replaces the pending slot.
  private func enqueue(_ payload: [String: Any]) {
    pendingLock.lock()
    pendingPayload = payload
    let shouldStart = !decoding
    if shouldStart { decoding = true }
    pendingLock.unlock()
    guard shouldStart else { return }
    decodeQueue.async { [weak self] in self?.drainDecodeQueue() }
  }

  private func drainDecodeQueue() {
    while true {
      pendingLock.lock()
      let payload = pendingPayload
      pendingPayload = nil
      if payload == nil { decoding = false }
      pendingLock.unlock()
      guard let payload else { return }
      guard let decoded = Self.decodeFrame(payload) else { continue }
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.stopped else { return }
        guard decoded.seq < 0 || decoded.seq >= self.lastRenderedSeq else { return }
        self.lastRenderedSeq = decoded.seq
        if let control = decoded.control { self.control = control }
        self.onFrame?(decoded)
      }
    }
  }

  private static func decodeFrame(_ payload: [String: Any]) -> Frame? {
    guard let base64 = payload["imageBase64"] as? String,
      let data = Data(base64Encoded: base64),
      let raw = UIImage(data: data)
    else { return nil }
    // UIImage(data:) defers the bitmap decode to first draw — on main. Force it here.
    let image = raw.preparingForDisplay() ?? raw
    let width = CGFloat(intValue(payload["width"]) ?? Int(image.size.width))
    let height = CGFloat(intValue(payload["height"]) ?? Int(image.size.height))
    return Frame(
      seq: intValue(payload["seq"]) ?? -1,
      image: image,
      viewport: CGSize(
        width: width > 0 ? width : image.size.width,
        height: height > 0 ? height : image.size.height),
      url: normalized(payload["url"]) ?? "",
      title: normalized(payload["title"]) ?? "",
      loading: (payload["loading"] as? Bool) ?? false,
      control: normalized(payload["control"])
    )
  }

  // MARK: - Outbound

  func takeControl(ttlSeconds: Int? = nil) { pushControl(action: "take", ttlSeconds: ttlSeconds) }
  func releaseControl() { pushControl(action: "release", ttlSeconds: nil) }

  private func pushControl(action: String, ttlSeconds: Int?) {
    guard canPush else { return }
    var payload: [String: Any] = ["action": action]
    if let ttlSeconds { payload["ttlSeconds"] = ttlSeconds }
    client?.push(topic: topic, event: "control", payload: payload)
  }

  func sendClick(at point: CGPoint) {
    sendInput(["kind": "click", "x": Int(point.x.rounded()), "y": Int(point.y.rounded())])
  }

  func sendText(_ text: String) {
    guard !text.isEmpty else { return }
    sendInput(["kind": "type", "text": text])
  }

  func sendKey(_ key: String) { sendInput(["kind": "key", "key": key]) }

  func sendNavigate(_ url: String) { sendInput(["kind": "navigate", "url": url]) }

  func sendBack() { sendInput(["kind": "back"]) }

  /// Coalesced to ~15/s: the channel drops anything past 20/s per session rather than queue it.
  func sendScroll(deltaY: CGFloat) {
    let now = Date().timeIntervalSince1970
    guard now - lastScrollSentAt >= 0.066 else { return }
    lastScrollSentAt = now
    sendInput(["kind": "scroll", "deltaY": Int(deltaY.rounded())])
  }

  func sendInput(_ payload: [String: Any]) {
    guard canPush, control == "user" else { return }
    client?.push(topic: topic, event: "input", payload: payload)
  }

  private var canPush: Bool { !stopped && joined && client != nil }

  // MARK: - Machine views (owner-only, read-only)

  struct ExecEntry {
    let seq: Int
    let cmd: String
    let cwd: String?
    let exitCode: Int
    let stdout: String
    let stderr: String
    let durationMs: Int
  }

  struct FileEntry {
    let path: String
    let isDirectory: Bool
    let bytes: Int
    var name: String { (path as NSString).lastPathComponent }
  }

  func fetchExecLog(since: Int = 0, completion: @escaping ([ExecEntry]) -> Void) {
    let path = "/api/agents/\(Self.escape(agentId))/computer/exec-log?since=\(since)&limit=40"
    get(path: path) { payload in
      let rows = (payload?["entries"] as? [[String: Any]]) ?? []
      completion(rows.compactMap(Self.execEntry))
    }
  }

  func fetchTree(path directory: String, completion: @escaping ([FileEntry]) -> Void) {
    let path =
      "/api/agents/\(Self.escape(agentId))/computer/tree?depth=1&path=\(Self.query(directory))"
    get(path: path) { payload in
      let rows = (payload?["entries"] as? [[String: Any]]) ?? []
      completion(rows.compactMap(Self.fileEntry).filter { $0.path != directory })
    }
  }

  func fetchFile(path file: String, completion: @escaping (String?) -> Void) {
    let path = "/api/agents/\(Self.escape(agentId))/computer/file?path=\(Self.query(file))"
    get(path: path) { payload in
      guard let base64 = Self.normalized(payload?["contentBase64"]),
        let data = Data(base64Encoded: base64)
      else {
        completion(nil)
        return
      }
      completion(String(data: data, encoding: .utf8))
    }
  }

  private func get(path: String, completion: @escaping ([String: Any]?) -> Void) {
    guard let url = Self.apiURL(api: api, path: path) else {
      DispatchQueue.main.async { completion(nil) }
      return
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    request.setValue("Bearer \(api.authToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) { data, response, _ in
      let ok = (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
      let payload = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
      DispatchQueue.main.async { completion(ok ? payload : nil) }
    }.resume()
  }

  private static func query(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
  }

  private static func execEntry(_ row: [String: Any]) -> ExecEntry? {
    guard let seq = intValue(row["seq"]) else { return nil }
    return ExecEntry(
      seq: seq,
      cmd: (row["cmd"] as? [String])?.joined(separator: " ") ?? "",
      cwd: normalized(row["cwd"]),
      exitCode: intValue(row["exitCode"]) ?? 0,
      stdout: (row["stdout"] as? String) ?? "",
      stderr: (row["stderr"] as? String) ?? "",
      durationMs: intValue(row["durationMs"]) ?? 0)
  }

  private static func fileEntry(_ row: [String: Any]) -> FileEntry? {
    guard let path = normalized(row["path"]) else { return nil }
    return FileEntry(
      path: path,
      isDirectory: normalized(row["type"]) == "dir",
      bytes: intValue(row["bytes"]) ?? 0)
  }

  // MARK: - Agent id + URL helpers

  private static var agentIdByPeerUserId: [String: String] = [:]
  private static let cacheLock = NSLock()

  private static func resolveAgentId(
    explicit: String?, chatId: String?, api: AppSessionConfig,
    completion: @escaping (String?) -> Void
  ) {
    if let explicit = normalized(explicit) {
      completion(explicit)
      return
    }
    // `peerUserId` hops the engine's serial queue, so never ask for it from the main thread.
    DispatchQueue.global(qos: .userInitiated).async {
      guard let chatId = normalized(chatId),
        let peerUserId = normalized(ChatEngine.shared.peerUserId(chatId: chatId))?.uppercased()
      else {
        completion(nil)
        return
      }
      cacheLock.lock()
      let cached = agentIdByPeerUserId[peerUserId]
      cacheLock.unlock()
      if let cached {
        completion(cached)
        return
      }
      guard let url = apiURL(api: api, path: "/api/agents") else {
        completion(nil)
        return
      }
      var request = URLRequest(url: url)
      request.timeoutInterval = 10
      request.setValue("Bearer \(api.authToken)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) { data, response, _ in
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
          let data,
          let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let items = payload["items"] as? [[String: Any]]
        else {
          completion(nil)
          return
        }
        var map: [String: String] = [:]
        for item in items {
          guard let id = normalized(item["id"]),
            let ownerUserId = normalized(item["userId"] ?? item["user_id"])?.uppercased()
          else { continue }
          map[ownerUserId] = id
        }
        cacheLock.lock()
        agentIdByPeerUserId.merge(map) { _, new in new }
        cacheLock.unlock()
        completion(map[peerUserId])
      }.resume()
    }
  }

  private static func apiURL(api: AppSessionConfig, path: String) -> URL? {
    var base = api.apiBaseURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    let root = base.lowercased().hasSuffix("/api") ? String(base.dropLast(4)) : base
    return URL(string: root + path)
  }

  private static func escape(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
  }

  private static func normalized(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func intValue(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let text = value as? String { return Int(text) }
    return nil
  }
}
