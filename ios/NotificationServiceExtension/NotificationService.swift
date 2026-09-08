import Intents
import os.log
import UIKit
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttemptContent: UNMutableNotificationContent?
  private var avatarDownloadTask: URLSessionDataTask?
  private var mediaDownloadTask: URLSessionDataTask?
  /// Guards against double delivery when donation completion races
  /// `serviceExtensionTimeWillExpire`.
  private var didDeliverContent = false
  private let logPrefix = "[VibeNotifyExt]"
  private let osLogger = OSLog(
    subsystem: "com.vibegram.app.NotificationServiceExtension",
    category: "NotificationService"
  )

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    log("didReceive id=\(request.identifier)")
    guard let bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
    else {
      log("mutableCopy failed; passing through")
      contentHandler(request.content)
      return
    }
    self.bestAttemptContent = bestAttemptContent

    let payload = payloadMetadata(from: request.content.userInfo)
    let payloadCheck = extractApsDiagnostics(from: request.content.userInfo)
    log(
      "payload diagnostics id=\(request.identifier) mutable-content=\(payloadCheck.mutableContent) hasAlert=\(payloadCheck.hasAlert) hasContentAvailable=\(payloadCheck.hasContentAvailable)"
    )

    // Keep related chat notifications grouped.
    if !payload.chatId.isEmpty {
      bestAttemptContent.threadIdentifier = "chat-\(payload.chatId)"
    }

    // Avatar URL can come from direct root fields or nested "data" payload.
    let userInfo = request.content.userInfo
    let nestedData = dictionaryValue(from: userInfo["data"])
    let bodyData = dictionaryValue(from: userInfo["body"])
    let apsData = dictionaryValue(from: userInfo["aps"])
    let apsAlertData = dictionaryValue(from: apsData?["alert"])
    log(
      "userInfo keys=\(Array(userInfo.keys).map { String(describing: $0) }.joined(separator: ","))")

    let avatarURLString: String? =
      firstNonEmptyString(in: [
        userInfo["fromUserImage"],
        nestedData?["fromUserImage"],
        bodyData?["fromUserImage"],
        apsAlertData?["fromUserImage"],
        userInfo["senderImage"],
        nestedData?["senderImage"],
        bodyData?["senderImage"],
        apsAlertData?["senderImage"],
      ])

    let rootRich = dictionaryValue(from: userInfo["richContent"])
    let nestedRich = dictionaryValue(from: nestedData?["richContent"])
    let bodyRich = dictionaryValue(from: bodyData?["richContent"])
    let apsAlertRich = dictionaryValue(from: apsAlertData?["richContent"])
    let rootRichAlt = dictionaryValue(from: userInfo["_richContent"])
    let nestedRichAlt = dictionaryValue(from: nestedData?["_richContent"])
    let bodyRichAlt = dictionaryValue(from: bodyData?["_richContent"])
    let apsAlertRichAlt = dictionaryValue(from: apsAlertData?["_richContent"])
    let mediaURLCandidate: String? =
      firstNonEmptyString(in: [
        rootRich?["image"],
        nestedRich?["image"],
        bodyRich?["image"],
        apsAlertRich?["image"],
        rootRichAlt?["image"],
        nestedRichAlt?["image"],
        bodyRichAlt?["image"],
        apsAlertRichAlt?["image"],
        userInfo["image"],
        nestedData?["image"],
        bodyData?["image"],
        apsAlertData?["image"],
      ])

    var mediaURLString = mediaURLCandidate
    if !shouldAttachMedia(for: payload), mediaURLString != nil {
      mediaURLString = nil
      log("media attachment skipped by message type type=\(payload.type) messageType=\(payload.messageType)")
    }
    if let avatarURLString, let mediaURL = mediaURLString,
      resourceIdentifier(for: avatarURLString) == resourceIdentifier(for: mediaURL)
    {
      mediaURLString = nil
      log("media attachment skipped because media image matches avatar image")
    }

    log(
      "resolved image urls avatar=\(avatarURLString != nil) media=\(mediaURLString != nil) nestedDataType=\(type(of: userInfo["data"] as Any)) bodyData=\(bodyData != nil) apsAlertData=\(apsAlertData != nil)"
    )

    var avatarData: Data?
    if let avatarURLString {
      avatarData = decodeInlineImageData(from: avatarURLString)
    }

    var mediaData: Data?
    if let mediaURLString {
      mediaData = decodeInlineImageData(from: mediaURLString)
    }

    let group = DispatchGroup()

    if avatarData == nil, let avatarString = avatarURLString, let url = URL(string: avatarString),
      ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    {
      group.enter()
      let req = URLRequest(
        url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10.0)
      avatarDownloadTask = URLSession.shared.dataTask(with: req) { data, response, error in
        if let error {
          self.log("avatar download failed error=\(error.localizedDescription)")
        } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
          self.log("avatar download non-2xx status=\(http.statusCode)")
        } else if let data = data, !data.isEmpty {
          avatarData = data
          self.log("avatar download ok bytes=\(data.count)")
        } else {
          self.log("avatar download returned empty data")
        }
        group.leave()
      }
      avatarDownloadTask?.resume()
    }

    if mediaData == nil, let mediaString = mediaURLString, let url = URL(string: mediaString),
      ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    {
      group.enter()
      let req = URLRequest(
        url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10.0)
      mediaDownloadTask = URLSession.shared.dataTask(with: req) { data, response, error in
        if let error {
          self.log("media download failed error=\(error.localizedDescription)")
        } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
          self.log("media download non-2xx status=\(http.statusCode)")
        } else if let data = data, !data.isEmpty {
          mediaData = data
          self.log("media download ok bytes=\(data.count)")
        } else {
          self.log("media download returned empty data")
        }
        group.leave()
      }
      mediaDownloadTask?.resume()
    }

    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      let normalizedAvatar = avatarData.flatMap { self.normalizedImageData($0, label: "avatar") }
      let normalizedMedia = mediaData.flatMap { self.normalizedImageData($0, label: "media") }
      self.finalizeNotification(
        avatarData: normalizedAvatar, mediaData: normalizedMedia, payload: payload)
    }
  }

  override func serviceExtensionTimeWillExpire() {
    log("serviceExtensionTimeWillExpire")
    avatarDownloadTask?.cancel()
    avatarDownloadTask = nil
    mediaDownloadTask?.cancel()
    mediaDownloadTask = nil
    emitBestAttemptContent()
  }

  private func emitBestAttemptContent() {
    // Donation completion and expiry can both try to finish the extension.
    // contentHandler must be invoked at most once.
    guard !didDeliverContent else {
      log("emitBestAttemptContent skipped (already delivered)")
      return
    }
    guard let contentHandler else {
      log("emitBestAttemptContent skipped (no contentHandler)")
      return
    }
    guard let bestAttemptContent else {
      log("emitBestAttemptContent skipped (no bestAttemptContent)")
      return
    }
    didDeliverContent = true
    self.contentHandler = nil
    log("emitBestAttemptContent")
    contentHandler(bestAttemptContent)
  }

  private func decodeInlineImageData(from raw: String) -> Data? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowered = trimmed.lowercased()
    if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
      return nil
    }
    if lowered.hasPrefix("data:image") {
      guard let commaIndex = raw.firstIndex(of: ",") else { return nil }
      let base64Part = String(raw[raw.index(after: commaIndex)...])
      return Data(base64Encoded: base64Part, options: .ignoreUnknownCharacters)
    }
    // Only attempt bare base64 decode when it looks like base64, not an arbitrary URL/text.
    let base64Allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=\n\r"
    )
    if trimmed.rangeOfCharacter(from: base64Allowed.inverted) != nil {
      return nil
    }
    if trimmed.count >= 80 {
      return Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters)
    }
    return nil
  }

  private func persistImageDataForIntent(_ data: Data) -> URL? {
    guard !data.isEmpty else { return nil }
    do {
      let fileManager = FileManager.default
      guard let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
      else { return nil }
      let fileURL = cachesDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
      try data.write(to: fileURL, options: .atomic)
      return fileURL
    } catch {
      log("persistImageDataForIntent failed: \(error.localizedDescription)")
      return nil
    }
  }

  private func finalizeNotification(avatarData: Data?, mediaData: Data?, payload: PayloadMetadata) {
    // Expiry may have already delivered; avoid starting a second communication path.
    guard !didDeliverContent else {
      log("finalize skipped (already delivered)")
      return
    }
    guard let mutableContent = bestAttemptContent else {
      log("finalize missing mutableContent")
      emitBestAttemptContent()
      return
    }

    log(
      "finalize avatarBytes=\(avatarData?.count ?? 0) mediaBytes=\(mediaData?.count ?? 0)")

    if let mediaData {
      attachMediaImage(mediaData, to: mutableContent)
    } else {
      log("finalize media attachment skipped: no media data")
    }

    // A DEBUG-only marker used to write "nse:img" / "nse:noimg" into the
    // subtitle. The subtitle is shown to the customer, so debug builds put that
    // string on the lock screen. The same information is already in the log
    // line above, which is where it belongs.

    // Apple requires INInteraction.donate to finish before
    // content.updating(from:). Emit only after that sequence completes.
    applyCommunicationStyle(to: mutableContent, payload: payload, avatarData: avatarData) {
      [weak self] in
      self?.emitBestAttemptContent()
    }
  }

  private func attachMediaImage(_ data: Data, to content: UNMutableNotificationContent) {
    guard !data.isEmpty else {
      log("attach media skipped empty data")
      return
    }

    do {
      let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      let fileURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("jpg")
      try data.write(to: fileURL, options: .atomic)
      let attachment = try UNNotificationAttachment(
        identifier: "media-attachment", url: fileURL, options: nil)
      content.attachments = [attachment]
      log("media attachment added file=\(fileURL.lastPathComponent)")
    } catch {
      // Keep notification alive even when attachment fails.
      log("media attachment failed error=\(error.localizedDescription)")
    }
  }

  /// Applies communication notification styling after a successful intent donation.
  ///
  /// Apple requires `INInteraction.donate` to finish before
  /// `UNNotificationContent.updating(from:)`. On donation failure the original
  /// mutable content is kept so the notification is never lost.
  private func applyCommunicationStyle(
    to content: UNMutableNotificationContent,
    payload: PayloadMetadata,
    avatarData: Data?,
    completion: @escaping () -> Void
  ) {
    let finishOnMain: () -> Void = {
      if Thread.isMainThread {
        completion()
      } else {
        DispatchQueue.main.async(execute: completion)
      }
    }

    let normalizedType = payload.type.lowercased()
    if normalizedType == "call-start" || normalizedType == "call_start"
      || normalizedType == "incoming_call"
    {
      log("communication style skipped for type=\(payload.type)")
      finishOnMain()
      return
    }

    if #available(iOSApplicationExtension 15.0, *) {
      let senderDisplayName = payload.fromUserName.isEmpty ? content.title : payload.fromUserName
      let senderIdentifier = payload.fromUserId.isEmpty ? senderDisplayName : payload.fromUserId
      let senderHandle = INPersonHandle(value: senderIdentifier, type: .unknown)

      var senderComponents = PersonNameComponents()
      senderComponents.nickname = senderDisplayName

      var senderImage: INImage? = nil
      if let avatarData, !avatarData.isEmpty {
        if let persistedURL = persistImageDataForIntent(avatarData) {
          senderImage = INImage(url: persistedURL)
          log("sender image created from persisted url")
        } else {
          senderImage = INImage(imageData: avatarData)
          log("sender image created from raw data")
        }
      } else {
        log("sender image skipped: avatar data unavailable")
      }

      if senderImage == nil, avatarData != nil {
        log("sender image init failed even though avatar data exists")
      }
      if senderImage == nil, let bundledDefault = bundledDefaultAvatarData() {
        senderImage = INImage(imageData: bundledDefault)
        log("sender image fallback loaded from bundled NotificationDefaultAvatar")
      } else if senderImage == nil,
        // Same renderer the app uses, seeded on the sender's user id, so the
        // notification shows the identical colour and initials as the chat list.
        let fallbackData = VibeAvatarFallback.imageData(
          displayName: payload.fromUserName.isEmpty ? senderDisplayName : payload.fromUserName,
          userId: payload.fromUserId.isEmpty ? nil : payload.fromUserId
        )
      {
        senderImage = INImage(imageData: fallbackData)
        log("sender image fallback rendered from shared avatar style")
      }
      if senderImage == nil {
        log("sender image is still nil after all fallback attempts")
      }

      let sender = INPerson(
        personHandle: senderHandle,
        nameComponents: senderComponents,
        displayName: senderDisplayName,
        image: senderImage,
        contactIdentifier: nil,
        customIdentifier: senderIdentifier,
        isMe: false,
        suggestionType: .none
      )

      let conversationId = payload.chatId.isEmpty ? content.threadIdentifier : payload.chatId
      let groupName: INSpeakableString? = nil

      // For an incoming direct message, iOS adds the current user as recipient.
      // Supplying a synthetic "me" participant conflicts with Apple's
      // communication-notification participant model.
      let intent = INSendMessageIntent(
        recipients: nil,
        outgoingMessageType: .outgoingMessageText,
        content: content.body,
        speakableGroupName: groupName,
        conversationIdentifier: conversationId,
        serviceName: "Vibe",
        sender: sender,
        attachments: nil
      )
      if let senderImage {
        intent.setImage(senderImage, forParameterNamed: \.sender)
      }

      let interaction = INInteraction(intent: intent, response: nil)
      interaction.direction = .incoming
      log("interaction donation starting")
      interaction.donate { [weak self] error in
        guard let self else {
          finishOnMain()
          return
        }

        // Donation finished (or failed). Only then may we update content.
        // Hop to main so bestAttemptContent / emit stay serialized with expiry.
        let applyAndFinish = {
          if let error {
            // Keep original mutable content so the notification is never lost.
            self.log("interaction donation failed error=\(error.localizedDescription)")
            finishOnMain()
            return
          }

          self.log("interaction donated")

          // If expiry already delivered, skip updating — contentHandler is done.
          if self.didDeliverContent {
            self.log("communication update skipped (already delivered)")
            finishOnMain()
            return
          }

          do {
            if let updatedContent = try content.updating(from: intent)
              as? UNMutableNotificationContent
            {
              self.bestAttemptContent = updatedContent
              self.log("communication style applied")
            } else {
              self.log("communication style skipped (updating returned immutable content)")
            }
          } catch {
            self.log("communication style apply failed error=\(error.localizedDescription)")
          }
          finishOnMain()
        }

        if Thread.isMainThread {
          applyAndFinish()
        } else {
          DispatchQueue.main.async(execute: applyAndFinish)
        }
      }
    } else {
      log("communication style unavailable (< iOS 15)")
      finishOnMain()
    }
  }

  private struct PayloadMetadata {
    let chatId: String
    let fromUserId: String
    let fromUserName: String
    let type: String
    let messageType: String
  }

  private struct ApsDiagnostics {
    let mutableContent: Int
    let hasAlert: Bool
    let hasContentAvailable: Bool
  }

  private func extractApsDiagnostics(from userInfo: [AnyHashable: Any]) -> ApsDiagnostics {
    guard let aps = userInfo["aps"] as? [String: Any] else {
      return ApsDiagnostics(mutableContent: 0, hasAlert: false, hasContentAvailable: false)
    }

    let mutableContent: Int = {
      if let value = aps["mutable-content"] as? Int { return value }
      if let value = aps["mutable-content"] as? NSNumber { return value.intValue }
      if let value = aps["mutableContent"] as? Int { return value }
      if let value = aps["mutableContent"] as? NSNumber { return value.intValue }
      if let value = aps["mutable-content"] as? String, let parsed = Int(value) { return parsed }
      if let value = aps["mutableContent"] as? String, let parsed = Int(value) { return parsed }
      return 0
    }()

    let hasContentAvailable: Bool = {
      if let value = aps["content-available"] as? Int { return value == 1 }
      if let value = aps["content-available"] as? NSNumber { return value.intValue == 1 }
      if let value = aps["contentAvailable"] as? Int { return value == 1 }
      if let value = aps["contentAvailable"] as? NSNumber { return value.intValue == 1 }
      return false
    }()

    return ApsDiagnostics(
      mutableContent: mutableContent,
      hasAlert: aps["alert"] != nil,
      hasContentAvailable: hasContentAvailable
    )
  }

  private func normalizedImageData(_ data: Data, label: String) -> Data? {
    guard !data.isEmpty else {
      log("\(label) data empty")
      return nil
    }

    guard let image = UIImage(data: data) else {
      log("\(label) decode failed bytes=\(data.count)")
      return nil
    }

    if let jpeg = image.jpegData(compressionQuality: 0.92) {
      if jpeg.count != data.count {
        log("\(label) normalized to jpeg bytes=\(jpeg.count)")
      }
      return jpeg
    }

    log("\(label) jpeg normalization failed; using original bytes=\(data.count)")
    return data
  }

  private func dictionaryValue(from value: Any?) -> [String: Any]? {
    if let dict = value as? [String: Any] {
      return dict
    }
    if let dictAnyHashable = value as? [AnyHashable: Any] {
      var converted: [String: Any] = [:]
      for (key, value) in dictAnyHashable {
        converted[String(describing: key)] = value
      }
      return converted
    }
    if let jsonString = value as? String,
      let jsonData = jsonString.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: jsonData),
      let dict = object as? [String: Any]
    {
      return dict
    }
    return nil
  }

  private func firstNonEmptyString(in candidates: [Any?]) -> String? {
    for candidate in candidates {
      if let value = candidate as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          return trimmed
        }
      }
    }
    return nil
  }

  private func shouldAttachMedia(for payload: PayloadMetadata) -> Bool {
    let normalizedMessageType =
      payload.messageType.isEmpty ? payload.type.lowercased() : payload.messageType.lowercased()
    switch normalizedMessageType {
    case "image", "video", "gif":
      return true
    default:
      return false
    }
  }

  private func resourceIdentifier(for raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return ""
    }
    if let url = URL(string: trimmed), let host = url.host {
      let hostValue = host.lowercased()
      let path = url.path.lowercased()
      let query = (url.query ?? "").lowercased()
      return "\(hostValue)\(path)?\(query)"
    }
    return trimmed.lowercased()
  }

  private func bundledDefaultAvatarData() -> Data? {
    let candidates = ["NotificationDefaultAvatar", "DefaultAvatar"]
    for name in candidates {
      if let image = UIImage(named: name, in: Bundle.main, compatibleWith: nil),
        let data = image.jpegData(compressionQuality: 0.92)
      {
        return data
      }
    }
    return nil
  }

  private func payloadMetadata(from userInfo: [AnyHashable: Any]) -> PayloadMetadata {
    let nestedData = dictionaryValue(from: userInfo["data"])
    let bodyData = dictionaryValue(from: userInfo["body"])
    let apsData = dictionaryValue(from: userInfo["aps"])
    let apsAlertData = dictionaryValue(from: apsData?["alert"])

    let chatId =
      (userInfo["chatId"] as? String)
      ?? (nestedData?["chatId"] as? String)
      ?? (bodyData?["chatId"] as? String)
      ?? (apsAlertData?["chatId"] as? String)
      ?? ""
    let fromUserId =
      (userInfo["fromUserId"] as? String)
      ?? (nestedData?["fromUserId"] as? String)
      ?? (bodyData?["fromUserId"] as? String)
      ?? (apsAlertData?["fromUserId"] as? String)
      ?? ""
    let fromUserName =
      (userInfo["fromUserName"] as? String)
      ?? (nestedData?["fromUserName"] as? String)
      ?? (bodyData?["fromUserName"] as? String)
      ?? (apsAlertData?["fromUserName"] as? String)
      ?? ""
    let type =
      (userInfo["type"] as? String)
      ?? (nestedData?["type"] as? String)
      ?? (bodyData?["type"] as? String)
      ?? (apsAlertData?["type"] as? String)
      ?? ""
    let messageType =
      (userInfo["messageType"] as? String)
      ?? (nestedData?["messageType"] as? String)
      ?? (bodyData?["messageType"] as? String)
      ?? (apsAlertData?["messageType"] as? String)
      ?? (userInfo["message_type"] as? String)
      ?? (nestedData?["message_type"] as? String)
      ?? (bodyData?["message_type"] as? String)
      ?? (apsAlertData?["message_type"] as? String)
      ?? ""

    return PayloadMetadata(
      chatId: chatId.trimmingCharacters(in: .whitespacesAndNewlines),
      fromUserId: fromUserId.trimmingCharacters(in: .whitespacesAndNewlines),
      fromUserName: fromUserName.trimmingCharacters(in: .whitespacesAndNewlines),
      type: type.trimmingCharacters(in: .whitespacesAndNewlines),
      messageType: messageType.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  private func log(_ message: String) {
    let formatted = "\(logPrefix) \(message)"
    os_log("%{public}@", log: osLogger, type: .default, formatted)
    NSLog("%@", formatted)
  }
}
