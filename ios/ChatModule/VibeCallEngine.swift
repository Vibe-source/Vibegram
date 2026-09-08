import Foundation

public final class VibeNativeCallEngine {
  public static let shared = VibeNativeCallEngine()
  public static let stateDidChangeNotification = Notification.Name("VibeNativeCallStateDidChange")

  private let queue = DispatchQueue(label: "vibe.native.call.engine")
  private let store = VibeNativeCallStore.shared
  private var turnRefreshInFlight = false

  private enum Keys {
    static let state = "state"
    static let callId = "callId"
    static let callType = "callType"
    static let direction = "direction"
    static let relayMode = "relayMode"
    static let socketUrl = "socketUrl"
    static let turnCredentialsUrl = "turnCredentialsUrl"
    static let configuredAt = "configuredAt"
    static let updatedAt = "updatedAt"
    static let note = "note"
    static let turnState = "turnState"
    static let turnIceServerCount = "turnIceServerCount"
    static let turnIceTransportPolicy = "turnIceTransportPolicy"
    static let turnServerIceTransportPolicy = "turnServerIceTransportPolicy"
    static let turnExpiresAt = "turnExpiresAt"
    static let turnLastFetchAt = "turnLastFetchAt"
    static let turnLastError = "turnLastError"
    static let signalingState = "signalingState"
    static let userChannelTopic = "userChannelTopic"
    static let signalingEventCount = "signalingEventCount"
    static let signalingInboundCount = "signalingInboundCount"
    static let signalingOutboundCount = "signalingOutboundCount"
    static let signalingLastEvent = "signalingLastEvent"
    static let signalingLastDirection = "signalingLastDirection"
    static let signalingLastTopic = "signalingLastTopic"
    static let signalingLastAt = "signalingLastAt"
    static let signalingLastError = "signalingLastError"
  }

  private var state: [String: Any] = [
    Keys.state: "idle",
    Keys.updatedAt: 0,
    Keys.turnState: "idle",
    Keys.signalingState: "idle",
  ]

  private init() {}

  public func configure(_ payload: [String: Any]) -> [String: Any] {
    let result = queue.sync {
      store.setNativeEngineConfig(payload)
      var next = state
      next[Keys.state] = "configured"
      next[Keys.relayMode] = payload["relayMode"] ?? payload["connectionMode"] ?? payload["iceTransportPolicy"]
      next[Keys.socketUrl] = payload["socketUrl"] ?? payload["signalingUrl"]
      next[Keys.turnCredentialsUrl] = payload["turnCredentialsUrl"] ?? payload["turnUrl"]
      next[Keys.userChannelTopic] = payload["userChannelTopic"] ?? payload["topic"]
      let now = Int(Date().timeIntervalSince1970 * 1000)
      next[Keys.configuredAt] = now
      next[Keys.updatedAt] = now
      next[Keys.signalingState] = "ready"
      next[Keys.note] = "Native call signaling configured."
      state = next
      NSLog("[VibeNativeCall][Engine] configure keys=[%@]", payload.keys.sorted().joined(separator: ","))
      return next
    }
    refreshTurnConfig(force: true)
    VibeNativeCallManager.shared.syncStoredPushTokens(reason: "call-engine-configure")
    return result
  }

  public func getConfig() -> [String: Any] {
    store.getNativeEngineConfig()
  }

  public func getStatus() -> [String: Any] {
    queue.sync { state }
  }

  public func getIceConfig() -> [String: Any] {
    store.getNativeIceConfig()
  }

  public func getSignalingJournal(limit: Int? = nil) -> [[String: Any]] {
    store.getNativeSignalingEvents(limit: limit)
  }

  @discardableResult
  public func clearSignalingJournal() -> [String: Any] {
    store.clearNativeSignalingEvents()
    let now = nowMs()
    return queue.sync {
      var next = state
      next[Keys.signalingEventCount] = 0
      next[Keys.signalingInboundCount] = 0
      next[Keys.signalingOutboundCount] = 0
      next[Keys.signalingLastEvent] = nil
      next[Keys.signalingLastDirection] = nil
      next[Keys.signalingLastTopic] = nil
      next[Keys.signalingLastError] = nil
      next[Keys.signalingLastAt] = now
      next[Keys.updatedAt] = now
      state = next
      return next
    }
  }

  @discardableResult
  public func refreshTurnConfig(force: Bool = false) -> [String: Any] {
    let config = store.getNativeEngineConfig()
    let now = nowMs()

    guard let urlString = normalizedString(config["turnCredentialsUrl"] ?? config["turnUrl"]),
          let url = URL(string: urlString)
    else {
      return queue.sync {
        var next = state
        next[Keys.turnState] = "missing-url"
        next[Keys.turnLastError] = "Missing turnCredentialsUrl"
        next[Keys.updatedAt] = now
        state = next
        return next
      }
    }

    let cachedIce = store.getNativeIceConfig()
    if !force,
       let expiresAt = intValue(cachedIce["expiresAt"]),
       expiresAt > (now + 5_000)
    {
      return queue.sync {
        var next = state
        next[Keys.turnState] = "ready"
        next[Keys.turnIceServerCount] = (cachedIce["iceServers"] as? [Any])?.count ?? 0
        next[Keys.turnIceTransportPolicy] = cachedIce["iceTransportPolicy"]
        next[Keys.turnServerIceTransportPolicy] = cachedIce["serverIceTransportPolicy"]
        next[Keys.turnExpiresAt] = cachedIce["expiresAt"]
        next[Keys.turnLastFetchAt] = cachedIce["fetchedAt"]
        next[Keys.turnLastError] = nil
        next[Keys.updatedAt] = now
        state = next
        return next
      }
    }

    let shouldForceRelay = forceRelayEnabled(config)
    let started = queue.sync {
      if turnRefreshInFlight {
        return false
      }
      turnRefreshInFlight = true
      var next = state
      next[Keys.turnState] = "fetching"
      next[Keys.turnLastError] = nil
      next[Keys.updatedAt] = now
      state = next
      return true
    }
    guard started else { return getStatus() }

    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    VibeHTTP.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      let finishedAt = self.nowMs()

      if let error {
        self.finishTurnRefreshError("network:\(error.localizedDescription)", at: finishedAt)
        return
      }

      if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
        self.finishTurnRefreshError("http:\(http.statusCode)", at: finishedAt)
        return
      }

      guard let data,
            let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        self.finishTurnRefreshError("invalid-json", at: finishedAt)
        return
      }

      let iceServers = (decoded["iceServers"] as? [Any]) ?? []
      let ttl = max(self.intValue(decoded["ttl"]) ?? 3600, 30)
      let serverPolicy = self.normalizeTransportPolicy(decoded["iceTransportPolicy"])
      let effectivePolicy = shouldForceRelay ? "relay" : serverPolicy
      let fetchedAt = finishedAt
      let expiresAt = fetchedAt + (ttl * 1000)

      let iceConfig: [String: Any] = [
        "iceServers": iceServers,
        "ttl": ttl,
        "fetchedAt": fetchedAt,
        "expiresAt": expiresAt,
        "serverIceTransportPolicy": serverPolicy,
        "iceTransportPolicy": effectivePolicy,
        "forceRelay": shouldForceRelay,
      ]
      self.store.setNativeIceConfig(iceConfig)

      self.queue.async {
        self.turnRefreshInFlight = false
        var next = self.state
        next[Keys.turnState] = "ready"
        next[Keys.turnIceServerCount] = iceServers.count
        next[Keys.turnIceTransportPolicy] = effectivePolicy
        next[Keys.turnServerIceTransportPolicy] = serverPolicy
        next[Keys.turnExpiresAt] = expiresAt
        next[Keys.turnLastFetchAt] = fetchedAt
        next[Keys.turnLastError] = nil
        next[Keys.updatedAt] = fetchedAt
        next[Keys.note] = "Native call signaling configured; TURN config ready."
        self.state = next
        NSLog(
          "[VibeNativeCall][Engine] turn fetch ok servers=%d policy=%@ forceRelay=%@",
          iceServers.count,
          effectivePolicy,
          shouldForceRelay ? "true" : "false"
        )
      }
    }.resume()

    return getStatus()
  }

  public func startOutgoing(_ payload: [String: Any]) -> [String: Any] {
    var callPayload = preparedCallPayload(payload, event: "call-start", direction: "outbound")
    let signal = ChatEngine.shared.sendCallSignal(callPayload)
    callPayload["signaling"] = signal
    callPayload["signalingAccepted"] = signal["accepted"] ?? false
    callPayload["signalingQueued"] = signal["queued"] ?? false
    callPayload["signalingRef"] = signal["ref"] ?? NSNull()
    recordSignalingEvent(callPayload, defaultEvent: "call-start", defaultDirection: "outbound")
    let accepted = boolValue(signal["accepted"])
    return transition(
      stateValue: accepted ? "ringing" : "failed",
      payload: callPayload,
      direction: "outgoing",
      note: signalingNote(signal, fallback: "Outgoing call routed through native signaling.")
    )
  }

  public func acceptIncoming(_ payload: [String: Any]) -> [String: Any] {
    var callPayload = preparedCallPayload(payload, event: "call-accepted", direction: "outbound")
    if normalizedString(callPayload["toUserId"]) == nil,
       let fromUserId = normalizedString(callPayload["fromUserId"] ?? callPayload["from_user_id"]) {
      callPayload["toUserId"] = fromUserId
    }
    let signal = ChatEngine.shared.sendCallSignal(callPayload)
    callPayload["signaling"] = signal
    callPayload["signalingAccepted"] = signal["accepted"] ?? false
    callPayload["signalingQueued"] = signal["queued"] ?? false
    callPayload["signalingRef"] = signal["ref"] ?? NSNull()
    recordSignalingEvent(callPayload, defaultEvent: "call-accepted", defaultDirection: "outbound")
    return transition(
      stateValue: "connecting",
      payload: callPayload,
      direction: "incoming",
      note: signalingNote(signal, fallback: "Incoming call accepted through native signaling.")
    )
  }

  public func failCall(_ payload: [String: Any], reason: String) -> [String: Any] {
    var callPayload = preparedCallPayload(payload, event: "call-failed", direction: "local")
    callPayload["failureReason"] = reason
    return transition(
      stateValue: "failed",
      payload: callPayload,
      direction: normalizedString(payload["direction"]),
      note: reason
    )
  }

  public func handleSignal(_ payload: [String: Any]) -> [String: Any] {
    let event =
      normalizedString(payload["event"])
      ?? (["call-start", "call-accepted", "call-end"].contains(normalizedString(payload["type"]) ?? "")
        ? normalizedString(payload["type"]) : nil)
      ?? "webrtc-signal"
    var callPayload = preparedCallPayload(payload, event: event, direction: "inbound")
    recordSignalingEvent(callPayload, defaultEvent: event, defaultDirection: "inbound")
    switch event {
    case "call-start":
      return transition(
        stateValue: "ringing",
        payload: callPayload,
        direction: "incoming",
        note: "Incoming call routed through native signaling."
      )
    case "call-accepted":
      return transition(
        stateValue: "connecting",
        payload: callPayload,
        direction: "outgoing",
        note: "Call accepted through native signaling."
      )
    case "call-end":
      callPayload["remote"] = true
      return endCall(callPayload)
    default:
      return queue.sync {
        var next = state
        next[Keys.updatedAt] = Int(Date().timeIntervalSince1970 * 1000)
        next["lastSignalType"] = payload["type"] ?? payload["signalType"]
        next[Keys.note] = "WebRTC signal routed through native signaling."
        state = next
        NSLog("[VibeNativeCall][Engine] handleSignal type=%@", String(describing: payload["type"] ?? payload["signalType"]))
        return next
      }
    }
  }

  public func endCall(_ payload: [String: Any]) -> [String: Any] {
    var callPayload = preparedCallPayload(
      payload,
      event: "call-end",
      direction: boolValue(payload["remote"]) ? "inbound" : "outbound"
    )
    if !boolValue(callPayload["remote"]) {
      if normalizedString(callPayload["toUserId"]) == nil,
         let target = remoteUserId(callPayload) {
        callPayload["toUserId"] = target
      }
      let signal = ChatEngine.shared.sendCallSignal(callPayload)
      callPayload["signaling"] = signal
      callPayload["signalingAccepted"] = signal["accepted"] ?? false
      callPayload["signalingQueued"] = signal["queued"] ?? false
      callPayload["signalingRef"] = signal["ref"] ?? NSNull()
    }
    let inferredDirection: String = boolValue(callPayload["remote"]) ? "inbound" : "outbound"
    recordSignalingEvent(callPayload, defaultEvent: "call-end", defaultDirection: inferredDirection)
    return transition(
      stateValue: "ended",
      payload: callPayload,
      direction: payload["direction"] as? String,
      note: "Call ended through native signaling."
    )
  }

  private func preparedCallPayload(
    _ payload: [String: Any],
    event: String,
    direction: String
  ) -> [String: Any] {
    var next = makeJsonSafeDictionary(payload)
    let now = nowMs()
    next["event"] = event
    next["direction"] = direction
    if normalizedString(next["callId"] ?? next["call_id"]) == nil {
      next["callId"] = "call_\(now)_\(UUID().uuidString.prefix(8))"
    }
    if normalizedString(next["callType"] ?? next["call_type"]) == nil {
      next["callType"] = "voice"
    }
    if let callId = normalizedString(next["call_id"]), normalizedString(next["callId"]) == nil {
      next["callId"] = callId
    }
    if let callType = normalizedString(next["call_type"]), normalizedString(next["callType"]) == nil {
      next["callType"] = callType
    }
    return next
  }

  private func remoteUserId(_ payload: [String: Any]) -> String? {
    normalizedString(payload["toUserId"] ?? payload["to_user_id"])
      ?? normalizedString(payload["remoteUserId"] ?? payload["remote_user_id"])
      ?? normalizedString(payload["fromUserId"] ?? payload["from_user_id"])
      ?? normalizedString(payload["peerUserId"] ?? payload["peer_user_id"])
  }

  private func signalingNote(_ signal: [String: Any], fallback: String) -> String {
    guard boolValue(signal["accepted"]) else {
      return "Native signaling rejected: \(normalizedString(signal["reason"]) ?? "unknown")."
    }
    if boolValue(signal["queued"]) {
      return "Native signaling queued until the user channel joins."
    }
    return fallback
  }

  private func transition(
    stateValue: String,
    payload: [String: Any],
    direction: String?,
    note: String
  ) -> [String: Any] {
    let nextState = queue.sync {
      var next = state
      next[Keys.state] = stateValue
      next[Keys.callId] = payload["callId"] ?? payload["call_id"]
      next[Keys.callType] = payload["callType"] ?? payload["call_type"]
      if let direction { next[Keys.direction] = direction }
      let passthroughKeys = [
        "toUserId", "to_user_id", "toUserName", "to_user_name", "toUserImage", "to_user_image",
        "fromUserId", "from_user_id", "fromUserName", "from_user_name", "fromUserImage",
        "from_user_image", "remoteUserId", "remote_user_id", "chatId", "chat_id",
        "signalingAccepted", "signalingQueued", "signalingRef", "failureReason",
      ]
      for key in passthroughKeys {
        if let value = payload[key] {
          next[key] = value
        }
      }
      next[Keys.updatedAt] = Int(Date().timeIntervalSince1970 * 1000)
      next[Keys.note] = note
      state = next
      NSLog(
        "[VibeNativeCall][Engine] transition state=%@ callId=%@ type=%@",
        stateValue,
        String(describing: next[Keys.callId] ?? "-"),
        String(describing: next[Keys.callType] ?? "-")
      )
      return next
    }
    DispatchQueue.main.async {
      NotificationCenter.default.post(
        name: Self.stateDidChangeNotification,
        object: self,
        userInfo: ["state": nextState]
      )
    }
    return nextState
  }

  private func finishTurnRefreshError(_ error: String, at timestamp: Int) {
    queue.async {
      self.turnRefreshInFlight = false
      var next = self.state
      next[Keys.turnState] = "error"
      next[Keys.turnLastError] = error
      next[Keys.turnLastFetchAt] = timestamp
      next[Keys.updatedAt] = timestamp
      self.state = next
      NSLog("[VibeNativeCall][Engine] turn fetch error=%@", error)
    }
  }

  private func recordSignalingEvent(
    _ payload: [String: Any],
    defaultEvent: String,
    defaultDirection: String
  ) {
    let ts = nowMs()
    let eventName = normalizedString(payload["event"]) ?? defaultEvent
    let direction = normalizedString(payload["direction"]) ?? defaultDirection
    let config = store.getNativeEngineConfig()
    let topic = normalizedString(payload["topic"]) ?? normalizedString(config["userChannelTopic"])
    var entry: [String: Any] = [
      "timestamp": ts,
      "event": eventName,
      "direction": direction,
      "payload": makeJsonSafeDictionary(payload),
    ]
    if let topic { entry["topic"] = topic }
    if let callId = payload["callId"] ?? payload["call_id"] { entry["callId"] = callId }
    if let callType = payload["callType"] ?? payload["call_type"] { entry["callType"] = callType }
    if let signalType = payload["type"] ?? payload["signalType"] { entry["signalType"] = signalType }
    store.appendNativeSignalingEvent(entry)

    queue.async {
      var next = self.state
      next[Keys.signalingState] = "mirroring"
      next[Keys.signalingLastEvent] = eventName
      next[Keys.signalingLastDirection] = direction
      next[Keys.signalingLastTopic] = topic
      next[Keys.signalingLastAt] = ts
      next[Keys.signalingLastError] = nil
      let total = (next[Keys.signalingEventCount] as? Int) ?? 0
      next[Keys.signalingEventCount] = total + 1
      if direction == "inbound" {
        next[Keys.signalingInboundCount] = ((next[Keys.signalingInboundCount] as? Int) ?? 0) + 1
      } else if direction == "outbound" {
        next[Keys.signalingOutboundCount] = ((next[Keys.signalingOutboundCount] as? Int) ?? 0) + 1
      }
      next[Keys.updatedAt] = ts
      self.state = next
      NSLog("[VibeNativeCall][Engine] signaling journal dir=%@ event=%@", direction, eventName)
    }
  }

  private func nowMs() -> Int {
    Int(Date().timeIntervalSince1970 * 1000)
  }

  private func normalizedString(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func intValue(_ value: Any?) -> Int? {
    switch value {
    case let int as Int:
      return int
    case let num as NSNumber:
      return num.intValue
    case let str as String:
      return Int(str)
    default:
      return nil
    }
  }

  private func boolValue(_ value: Any?) -> Bool {
    switch value {
    case let bool as Bool:
      return bool
    case let num as NSNumber:
      return num.boolValue
    case let str as String:
      let raw = str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return raw == "1" || raw == "true" || raw == "yes"
    default:
      return false
    }
  }

  private func forceRelayEnabled(_ config: [String: Any]) -> Bool {
    if boolValue(config["forceRelay"]) { return true }
    if normalizeTransportPolicy(config["relayMode"]) == "relay" { return true }
    if normalizeTransportPolicy(config["connectionMode"]) == "relay" { return true }
    return false
  }

  private func normalizeTransportPolicy(_ value: Any?) -> String {
    guard let raw = normalizedString(value)?.lowercased() else { return "all" }
    return raw == "relay" ? "relay" : "all"
  }

  private func makeJsonSafeDictionary(_ value: [String: Any]) -> [String: Any] {
    if JSONSerialization.isValidJSONObject(value) {
      return value
    }
    var out: [String: Any] = [:]
    for (key, raw) in value {
      out[key] = makeJsonSafeValue(raw)
    }
    if JSONSerialization.isValidJSONObject(out) {
      return out
    }
    return ["raw": String(describing: value)]
  }

  private func makeJsonSafeValue(_ value: Any) -> Any {
    switch value {
    case let dict as [String: Any]:
      return makeJsonSafeDictionary(dict)
    case let arr as [Any]:
      return arr.map { makeJsonSafeValue($0) }
    case is NSString, is NSNumber, is NSNull:
      return value
    case let str as String:
      return str
    case let num as Int:
      return num
    case let num as Double:
      return num
    case let num as Float:
      return Double(num)
    case let bool as Bool:
      return bool
    default:
      return String(describing: value)
    }
  }
}
