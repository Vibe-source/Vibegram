import AVFoundation
import CallKit
import Foundation
import PushKit
import UIKit
import UserNotifications

public final class VibeNativeCallManager: NSObject {
  public static let shared = VibeNativeCallManager()

  private let store = VibeNativeCallStore.shared
  private lazy var provider: CXProvider = {
    let config = CXProviderConfiguration()
    // `localizedName` is derived from the app bundle on newer SDKs.
    config.supportsVideo = true
    config.maximumCallsPerCallGroup = 1
    config.maximumCallGroups = 1
    config.supportedHandleTypes = [.generic]
    config.includesCallsInRecents = false
    return CXProvider(configuration: config)
  }()
  private let callController = CXCallController()
  private var pushRegistry: PKPushRegistry?
  private var started = false
  private var foregroundBannerCallIds = Set<String>()
  private let pushSyncQueue = DispatchQueue(label: "vibe.native.call.push-sync")
  private var lastPushSyncSignature: String?
  private var pushSyncInFlight = false
  private var pushSyncNeedsRetry = false
  private var pushSyncRetryForce = false

  private override init() {
    super.init()
  }

  public func start() {
    DispatchQueue.main.async {
      self.startOnMain()
    }
  }

  public func refreshNotificationRegistration(reason: String, completion: ((Bool) -> Void)? = nil) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.startOnMain()
      self.syncStoredPushTokens(reason: "\(reason)-preflight", force: true)

      let center = UNUserNotificationCenter.current()
      center.getNotificationSettings { [weak self] settings in
        guard let self else { return }
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
          self.registerForRemoteNotifications(reason: reason, authorization: "\(settings.authorizationStatus.rawValue)")
          DispatchQueue.main.async { completion?(true) }
        case .notDetermined:
          center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            guard let self else { return }
            NSLog(
              "[VibeNativeCall] notification refresh auth reason=%@ granted=%@ error=%@",
              reason,
              granted ? "true" : "false",
              error?.localizedDescription ?? "nil"
            )
            if granted {
              self.registerForRemoteNotifications(reason: reason, authorization: "granted")
            }
            DispatchQueue.main.async { completion?(granted) }
          }
        case .denied:
          NSLog("[VibeNativeCall] notification refresh skipped reason=%@ authorization=denied", reason)
          DispatchQueue.main.async { completion?(false) }
        @unknown default:
          NSLog(
            "[VibeNativeCall] notification refresh skipped reason=%@ authorization=unknown:%ld",
            reason,
            settings.authorizationStatus.rawValue
          )
          DispatchQueue.main.async { completion?(false) }
        }
      }
    }
  }

  public func handleRemoteNotification(userInfo: [AnyHashable: Any], preferSystemUI: Bool = true) -> Bool {
    NSLog("[VibeNativeCall] handleRemoteNotification keys=[%@]", userInfo.keys.map { String(describing: $0) }.sorted().joined(separator: ","))
    guard let payload = normalizeIncomingCallPayload(userInfo: userInfo) else {
      NSLog("[VibeNativeCall] handleRemoteNotification ignored reason=normalizeFailed")
      return false
    }
    NSLog("[VibeNativeCall] handleRemoteNotification normalized callId=%@ callType=%@ fromUser=%@", payload["callId"] ?? "-", payload["callType"] ?? "-", payload["fromUserId"] ?? "-")
    if !preferSystemUI {
      _ = VibeNativeCallEngine.shared.handleSignal(payload.reduce(into: [String: Any]()) {
        $0[$1.key] = $1.value
      })
      return true
    }
    reportIncomingCall(payload: payload, source: "remoteNotification")
    return true
  }

  public func clearIncomingCallUi(callId: String?) {
    guard let callId, !callId.isEmpty else {
      NSLog("[VibeNativeCall] clearIncomingCallUi skipped reason=missingCallId")
      return
    }
    guard let uuid = store.uuid(forCallId: callId) else {
      NSLog("[VibeNativeCall] clearIncomingCallUi skipped reason=uuidNotFound callId=%@", callId)
      return
    }
    NSLog("[VibeNativeCall] clearIncomingCallUi callId=%@ uuid=%@", callId, uuid.uuidString)
    provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
    store.clearActiveCall(callId: callId)
  }

  public func presentForegroundIncomingBanner(_ payload: [String: Any]) {
    guard let normalized = normalizeIncomingCallPayload(userInfo: payload.reduce(into: [AnyHashable: Any]()) {
      $0[$1.key] = $1.value
    }) else {
      NSLog("[VibeNativeCall] foregroundBanner skipped reason=normalizeFailed")
      return
    }
    let callId = normalized["callId"] ?? ""
    guard !callId.isEmpty else { return }
    guard !foregroundBannerCallIds.contains(callId) else {
      NSLog("[VibeNativeCall] foregroundBanner skipped duplicate callId=%@", callId)
      return
    }
    foregroundBannerCallIds.insert(callId)

    let center = UNUserNotificationCenter.current()
    let content = UNMutableNotificationContent()
    content.categoryIdentifier = Self.foregroundCallCategoryIdentifier
    content.threadIdentifier = callId
    content.title = normalized["fromUserName"] ?? normalized["fromUserId"] ?? "Incoming call"
    content.body = "Incoming \((normalized["callType"] ?? "voice") == "video" ? "video" : "voice") call"
    content.sound = .default
    content.userInfo = normalized
    let request = UNNotificationRequest(
      identifier: "vibe.foreground.call.\(callId)",
      content: content,
      trigger: nil
    )
    center.add(request) { error in
      if let error {
        NSLog("[VibeNativeCall] foregroundBanner failed callId=%@ error=%@", callId, error.localizedDescription)
      } else {
        NSLog("[VibeNativeCall] foregroundBanner scheduled callId=%@", callId)
      }
    }
  }

  public static let foregroundCallCategoryIdentifier = "VIBE_INCOMING_CALL"
  public static let foregroundCallAcceptAction = "VIBE_CALL_ACCEPT"
  public static let foregroundCallDeclineAction = "VIBE_CALL_DECLINE"

  public func setApnsDeviceToken(_ tokenData: Data) {
    let token = tokenData.map { String(format: "%02x", $0) }.joined()
    store.setApnsToken(token)
    NSLog("[VibeNativeCall] APNs token updated len=%d", token.count)
    syncStoredPushTokens(reason: "apns-token")
  }

  public func clearApnsDeviceToken() {
    store.setApnsToken(nil)
    NSLog("[VibeNativeCall] APNs token cleared")
    syncStoredPushTokens(reason: "apns-token-invalidated")
  }

  public func syncStoredPushTokens(reason: String, force: Bool = false) {
    pushSyncQueue.async { [weak self] in
      self?.syncStoredPushTokensLocked(reason: reason, force: force)
    }
  }

  private func startOnMain() {
    guard !started else {
      NSLog("[VibeNativeCall] start skipped alreadyStarted=true")
      return
    }
    started = true
    NSLog("[VibeNativeCall] start begin mainThread=%@", Thread.isMainThread ? "true" : "false")
    provider.setDelegate(self, queue: nil)
    NSLog("[VibeNativeCall] CXProvider delegate set")
    let registry = PKPushRegistry(queue: DispatchQueue.main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    pushRegistry = registry
    NSLog("[VibeNativeCall] PKPushRegistry configured desiredPushTypes=%@", String(describing: registry.desiredPushTypes))
    syncStoredPushTokens(reason: "start")
  }

  private func registerForRemoteNotifications(reason: String, authorization: String) {
    DispatchQueue.main.async { [weak self] in
      NSLog(
        "[VibeNativeCall] notification registration refresh reason=%@ authorization=%@",
        reason,
        authorization
      )
      UIApplication.shared.registerForRemoteNotifications()
      self?.syncStoredPushTokens(reason: "\(reason)-register", force: true)
    }
  }

  private func reportIncomingCall(payload: [String: String], source: String) {
    let callId = payload["callId"] ?? UUID().uuidString
    let uuid = store.uuid(forCallId: callId) ?? UUID()
    NSLog(
      "[VibeNativeCall] reportIncomingCall source=%@ callId=%@ uuid=%@ fromUser=%@ callType=%@",
      source, callId, uuid.uuidString, payload["fromUserId"] ?? "-", payload["callType"] ?? "-"
    )
    let update = CXCallUpdate()
    let callerName = payload["fromUserName"] ?? payload["fromUserId"] ?? "Incoming call"
    update.localizedCallerName = callerName
    update.remoteHandle = CXHandle(type: .generic, value: payload["fromUserId"] ?? callerName)
    update.hasVideo = (payload["callType"] ?? "voice") == "video"
    update.supportsHolding = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false

    store.setActiveCall(uuid: uuid, payload: payload)
    var incomingEventPayload = payload
    incomingEventPayload["nativeSource"] = source
    store.enqueueEvent(type: "incomingCall", payload: incomingEventPayload)

    provider.reportNewIncomingCall(with: uuid, update: update) { error in
      if let error {
        NSLog("[VibeNativeCall] reportNewIncomingCall failed callId=%@ error=%@", callId, error.localizedDescription)
        VibeLog.error(
          "reportNewIncomingCall failed",
          category: "call",
          metadata: [
            "source": source,
            "callId": callId,
            "error": error.localizedDescription,
          ]
        )
      } else {
        VibeDebugLog.log("[VibeNativeCall] reportNewIncomingCall ok callId=%@ uuid=%@", callId, uuid.uuidString)
      }
    }
  }

  private func syncStoredPushTokensLocked(reason: String, force: Bool) {
    if pushSyncInFlight {
      pushSyncNeedsRetry = true
      pushSyncRetryForce = pushSyncRetryForce || force
      VibeDebugLog.log("[VibeNativeCall] push token sync skipped reason=%@ state=inFlight", reason)
      return
    }

    let tokens = store.getPushTokens()
    let apns = normalizedString(tokens["apns"])
    let voip = normalizedString(tokens["voip"] ?? tokens["apns_voip"])
    guard apns != nil || voip != nil else {
      VibeDebugLog.log("[VibeNativeCall] push token sync skipped reason=%@ missingTokens=true", reason)
      return
    }

    guard let config = resolvePushSyncConfig() else {
      VibeDebugLog.log("[VibeNativeCall] push token sync skipped reason=%@ missingSession=true", reason)
      VibeLog.warning(
        "push token sync skipped: missing session",
        category: "push",
        metadata: ["reason": reason]
      )
      return
    }

    var pushTokens: [String: String] = [:]
    if let apns { pushTokens["apns"] = apns }
    if let voip { pushTokens["apns_voip"] = voip }

    let signature = [
      config.userId,
      config.apiBaseUrl,
      apns ?? "",
      voip ?? "",
    ].joined(separator: "|")
    if !force && lastPushSyncSignature == signature {
      VibeDebugLog.log("[VibeNativeCall] push token sync skipped reason=%@ unchanged=true", reason)
      return
    }

    guard let url = URL(string: "\(config.apiBaseUrl)/api/user/profile") else {
      VibeDebugLog.log("[VibeNativeCall] push token sync skipped reason=%@ invalidURL=true", reason)
      VibeLog.error(
        "push token sync skipped: invalid url",
        category: "push",
        metadata: ["reason": reason, "host": URL(string: config.apiBaseUrl)?.host ?? "?"]
      )
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "userId": config.userId,
      "pushTokens": pushTokens,
    ])

    pushSyncInFlight = true
    VibeDebugLog.log(
      "[VibeNativeCall] push token sync start reason=%@ userId=%@ apns=%@ voip=%@",
      reason,
      config.userId,
      apns == nil ? "false" : "true",
      voip == nil ? "false" : "true"
    )
    VibeHTTP.shared.dataTask(with: request) { [weak self] _, response, error in
      guard let self else { return }
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      self.pushSyncQueue.async {
        self.pushSyncInFlight = false
        let shouldRetry = self.pushSyncNeedsRetry
        let shouldRetryForce = self.pushSyncRetryForce
        self.pushSyncNeedsRetry = false
        self.pushSyncRetryForce = false
        if let error {
          NSLog("[VibeNativeCall] push token sync failed reason=%@ error=%@", reason, error.localizedDescription)
          VibeLog.error("push token sync failed", category: "push", metadata: ["reason": reason, "error": error.localizedDescription])
          if shouldRetry {
            self.syncStoredPushTokensLocked(reason: "queued-after-\(reason)", force: shouldRetryForce)
          }
          return
        }
        if (200...299).contains(status) {
          self.lastPushSyncSignature = signature
          VibeDebugLog.log("[VibeNativeCall] push token sync ok reason=%@ status=%d", reason, status)
        } else {
          NSLog("[VibeNativeCall] push token sync failed reason=%@ status=%d", reason, status)
          VibeLog.error("push token sync failed", category: "push", metadata: ["reason": reason, "status": String(status)])
        }
        if shouldRetry {
          self.syncStoredPushTokensLocked(reason: "queued-after-\(reason)", force: shouldRetryForce)
        }
      }
    }.resume()
  }

  private func resolvePushSyncConfig() -> (apiBaseUrl: String, userId: String, authToken: String)? {
    let engineConfig = ChatEngineStore.shared.getConfig()
    let callConfig = store.getNativeEngineConfig()
    guard
      let userId = normalizedString(engineConfig["userId"] ?? callConfig["userId"]),
      let authToken = normalizedString(
        engineConfig["authToken"] ?? engineConfig["token"] ?? callConfig["authToken"] ?? callConfig["token"])
    else {
      return nil
    }
    let rawBase =
      normalizedString(
        engineConfig["apiBaseUrl"] ?? engineConfig["baseUrl"] ?? callConfig["apiBaseUrl"] ?? callConfig["baseUrl"])
      ?? "https://api.vibegram.io"
    let apiBaseUrl = rawBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return (apiBaseUrl, userId, authToken)
  }

  private func normalizeIncomingCallPayload(userInfo: [AnyHashable: Any]) -> [String: String]? {
    func string(_ value: Any?) -> String? {
      guard let text = value as? String else { return nil }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }

    func dict(_ value: Any?) -> [String: Any]? {
      if let map = value as? [String: Any] { return map }
      if let map = value as? [AnyHashable: Any] {
        var normalized: [String: Any] = [:]
        for (key, val) in map {
          normalized[String(describing: key)] = val
        }
        return normalized
      }
      if let raw = value as? String,
         let data = raw.data(using: .utf8),
         let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return parsed
      }
      return nil
    }

    let root = userInfo.reduce(into: [String: Any]()) { partial, entry in
      partial[String(describing: entry.key)] = entry.value
    }
    NSLog("[VibeNativeCall] normalizeIncomingCallPayload rootKeys=[%@]", root.keys.sorted().joined(separator: ","))
    let candidates = [root, dict(root["data"]), dict(root["body"]), dict(root["payload"])].compactMap { $0 }
    NSLog("[VibeNativeCall] normalizeIncomingCallPayload candidateCount=%d", candidates.count)

    func pick(_ keys: [String]) -> String? {
      for candidate in candidates {
        for key in keys {
          if let value = string(candidate[key]) { return value }
        }
      }
      return nil
    }

    let callId = pick(["callId", "call_id", "callUUID", "call_uuid"])
    let fromUserId = pick(["fromUserId", "from_user_id", "callerId", "caller_id", "userId", "user_id"])
    guard let callId, let fromUserId else {
      NSLog(
        "[VibeNativeCall] normalizeIncomingCallPayload missing callId/fromUserId callId=%@ fromUserId=%@",
        callId ?? "nil", fromUserId ?? "nil"
      )
      return nil
    }
    let event = (pick(["type", "event"]) ?? "").lowercased()
    let callTypeRaw = (pick(["callType", "call_type"]) ?? "").lowercased()
    let isCallEvent = ["call-start", "call_start", "incoming-call", "incoming_call", "call"].contains(event)
    let hasCallType = callTypeRaw == "voice" || callTypeRaw == "video"
    guard isCallEvent || hasCallType else {
      NSLog("[VibeNativeCall] normalizeIncomingCallPayload rejected event=%@ callType=%@", event, callTypeRaw)
      return nil
    }

    var result: [String: String] = [
      "type": "call-start",
      "event": "call-start",
      "callId": callId,
      "fromUserId": fromUserId,
      "fromUserName": pick(["fromUserName", "from_user_name", "callerName", "caller_name", "userName", "user_name"]) ?? fromUserId,
      "callType": callTypeRaw == "video" ? "video" : "voice",
    ]
    if let image = pick(["fromUserImage", "from_user_image", "callerImage", "caller_image", "userImage", "user_image"]) {
      result["fromUserImage"] = image
    }
    NSLog(
      "[VibeNativeCall] normalizeIncomingCallPayload ok callId=%@ event=%@ callType=%@ fromUser=%@",
      callId, event, result["callType"] ?? "-", fromUserId
    )
    return result
  }

  private func normalizedString(_ value: Any?) -> String? {
    guard let value else { return nil }
    // Cast before describing. String(describing:) on a nested Optional renders
    // it as the literal text Optional("…"), which is how a valid APNs token
    // became an invalid 76-character string. Casting unwraps instead.
    if let text = value as? String {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let number = value as? NSNumber { return number.stringValue }
    let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }
}

extension VibeNativeCallManager: PKPushRegistryDelegate {
  public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    NSLog("[VibeNativeCall] PKPush didUpdateCredentials type=%@", type.rawValue)
    guard type == .voIP else { return }
    let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    store.setVoipToken(token)
    NSLog("[VibeNativeCall] VoIP token updated len=%d", token.count)
    syncStoredPushTokens(reason: "voip-token")
  }

  public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    NSLog("[VibeNativeCall] PKPush didInvalidateToken type=%@", type.rawValue)
    guard type == .voIP else { return }
    store.setVoipToken(nil)
    syncStoredPushTokens(reason: "voip-token-invalidated")
  }

  public func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    defer { completion() }
    NSLog("[VibeNativeCall] PKPush didReceiveIncomingPush type=%@ keys=[%@]", type.rawValue, payload.dictionaryPayload.keys.map { String(describing: $0) }.sorted().joined(separator: ","))
    guard type == .voIP else { return }
    guard let normalized = normalizeIncomingCallPayload(userInfo: payload.dictionaryPayload) else {
      NSLog("[VibeNativeCall] PKPush incomingPush ignored reason=normalizeFailed")
      VibeLog.warning(
        "voip push ignored: normalize failed",
        category: "call",
        metadata: [
          "keys": payload.dictionaryPayload.keys.map { String(describing: $0) }.sorted().joined(separator: ",")
        ]
      )
      return
    }
    NSLog("[VibeNativeCall] PKPush incomingPush normalized callId=%@ fromUser=%@", normalized["callId"] ?? "-", normalized["fromUserId"] ?? "-")
    reportIncomingCall(payload: normalized, source: "voip")
  }
}

extension VibeNativeCallManager: CXProviderDelegate {
  public func providerDidReset(_ provider: CXProvider) {
    NSLog("[VibeNativeCall] CXProvider providerDidReset")
  }

  public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    NSLog("[VibeNativeCall] CXProvider answer action uuid=%@", action.callUUID.uuidString)
    if let payload = store.payload(for: action.callUUID) {
      var eventPayload = payload
      eventPayload["action"] = "answer"
      store.enqueueEvent(type: "callAction", payload: eventPayload)
      _ = VibeNativeCallEngine.shared.acceptIncoming(eventPayload.reduce(into: [String: Any]()) {
        $0[$1.key] = $1.value
      })
    }
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    NSLog("[VibeNativeCall] CXProvider end action uuid=%@", action.callUUID.uuidString)
    if let payload = store.payload(for: action.callUUID) {
      var eventPayload = payload
      eventPayload["action"] = "decline"
      store.enqueueEvent(type: "callAction", payload: eventPayload)
      _ = VibeNativeCallEngine.shared.endCall(eventPayload.reduce(into: [String: Any]()) {
        $0[$1.key] = $1.value
      })
      store.clearActiveCall(uuid: action.callUUID)
    }
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    NSLog("[VibeNativeCall] CXProvider didActivateAudioSession")
  }
  public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    NSLog("[VibeNativeCall] CXProvider didDeactivateAudioSession")
  }
}
