import CryptoKit
import Foundation
import Network
import OSLog
import Security
import UIKit

private let chatEngineUITraceLogger = Logger(
  subsystem: "com.mohammadshayani.vibe.native",
  category: "UITrace"
)

private func chatEngineUITrace(_ message: String) {
  VibeDebugLog.notice(logger: chatEngineUITraceLogger, message)
  VibeDebugLog.log("[VibeUITrace] %@", message)
}

private struct ChatEngineHybridPayload: Decodable {
  let iv: String
  let c: String
  let k: String?
  let s: String?
  let g: String?
}

private struct ChatIngestDelta {
  let insertedIds: [String]
  let updatedIds: [String]
  let deletedIds: [String]
}

/// Message-dict keys whose ABSENCE means "off".
extension ChatEngine {
  fileprivate static let ingestTransientMessageKeys: Set<String> = [
    "isStreaming", "is_streaming", "uploadProgress", "upload_progress",
  ]

  fileprivate static let ingestDurableAttachmentKeys: [String] = [
    "agentBridgeAttachmentsEnc", "attachmentThumbnailsB64",
  ]
}

private func chatEngineReadDERLength(bytes: [UInt8], offset: inout Int) -> Int? {
  guard offset < bytes.count else { return nil }
  let first = Int(bytes[offset])
  offset += 1
  if (first & 0x80) == 0 { return first }
  let count = first & 0x7f
  guard count > 0, count <= 4, offset + count <= bytes.count else { return nil }
  var value = 0
  for _ in 0..<count {
    value = (value << 8) | Int(bytes[offset])
    offset += 1
  }
  return value
}

private func chatEngineExtractPKCS1FromPKCS8(_ data: Data) -> Data? {
  let bytes = [UInt8](data)
  var offset = 0
  guard offset < bytes.count, bytes[offset] == 0x30 else { return nil }
  offset += 1
  guard let seqLength = chatEngineReadDERLength(bytes: bytes, offset: &offset) else { return nil }
  let seqEnd = offset + seqLength
  guard seqEnd <= bytes.count else { return nil }
  guard offset < seqEnd, bytes[offset] == 0x02 else { return nil }
  offset += 1
  guard let versionLength = chatEngineReadDERLength(bytes: bytes, offset: &offset) else {
    return nil
  }
  offset += versionLength
  guard offset < seqEnd, bytes[offset] == 0x30 else { return nil }
  offset += 1
  guard let algLength = chatEngineReadDERLength(bytes: bytes, offset: &offset) else { return nil }
  offset += algLength
  guard offset < seqEnd, bytes[offset] == 0x04 else { return nil }
  offset += 1
  guard let keyLength = chatEngineReadDERLength(bytes: bytes, offset: &offset) else { return nil }
  let start = offset
  let end = start + keyLength
  guard end <= seqEnd else { return nil }
  return data.subdata(in: start..<end)
}

private func chatEngineDecodePEM(_ pem: String) -> Data? {
  let normalized =
    pem
    .replacingOccurrences(of: "\\r\\n", with: "\n")
    .replacingOccurrences(of: "\\r", with: "\n")
    .replacingOccurrences(of: "\\n", with: "\n")
  let sanitized =
    normalized
    .replacingOccurrences(of: "-----BEGIN [^-]+-----", with: "", options: .regularExpression)
    .replacingOccurrences(of: "-----END [^-]+-----", with: "", options: .regularExpression)
  return Data(base64Encoded: sanitized, options: .ignoreUnknownCharacters)
}

private func chatEnginePrivateKey(from pem: String) -> SecKey? {
  guard let keyData = chatEngineDecodePEM(pem) else {
    print(
      "[ChatEngine] chatEnginePrivateKey — PEM decode returned nil, pemLen=\(pem.count) prefix=\(pem.prefix(50))"
    )
    return nil
  }
  let attrs: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
    kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
    kSecAttrKeySizeInBits as String: 2048,
  ]
  var error: Unmanaged<CFError>?

  let isPKCS8 = pem.contains("BEGIN PRIVATE KEY") && !pem.contains("BEGIN RSA PRIVATE KEY")
  let targetData = (isPKCS8 ? chatEngineExtractPKCS1FromPKCS8(keyData) : nil) ?? keyData

  if let key = SecKeyCreateWithData(targetData as CFData, attrs as CFDictionary, &error) {
    return key
  }

  let attrsNoSize: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
    kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
  ]
  error = nil
  if let key = SecKeyCreateWithData(targetData as CFData, attrsNoSize as CFDictionary, &error) {
    return key
  }

  let errDesc: String
  if let e = error {
    errDesc = String(describing: e.takeUnretainedValue())
  } else {
    errDesc = "nil"
  }
  let firstBytes = keyData.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
  print(
    "[ChatEngine] chatEnginePrivateKey FAILED — derLen=\(keyData.count) firstBytes=[\(firstBytes)] pemPrefix=\(pem.prefix(40)) error=\(errDesc)"
  )
  return nil
}

private func chatEngineRSADecryptOAEP(privateKey: SecKey, encrypted: Data) -> Data? {
  var error: Unmanaged<CFError>?
  let decrypted =
    SecKeyCreateDecryptedData(
      privateKey,
      .rsaEncryptionOAEPSHA256,
      encrypted as CFData,
      &error
    ) as Data?
  _ = error?.takeRetainedValue()
  return decrypted
}

private func chatEnginePublicKey(from pem: String) -> SecKey? {
  guard let keyData = chatEngineDecodePEM(pem) else { return nil }
  let attrs: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
    kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
  ]
  var error: Unmanaged<CFError>?
  let key = SecKeyCreateWithData(keyData as CFData, attrs as CFDictionary, &error)
  _ = error?.takeRetainedValue()
  return key
}

private func chatEngineRSAEncryptOAEP(publicKey: SecKey, plain: Data) -> Data? {
  var error: Unmanaged<CFError>?
  let encrypted =
    SecKeyCreateEncryptedData(
      publicKey,
      .rsaEncryptionOAEPSHA256,
      plain as CFData,
      &error
    ) as Data?
  _ = error?.takeRetainedValue()
  return encrypted
}

private func chatEngineRandomBytes(count: Int) throws -> Data {
  var data = Data(count: count)
  let status = data.withUnsafeMutableBytes { buffer in
    guard let baseAddress = buffer.baseAddress else { return errSecParam }
    return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
  }
  if status != errSecSuccess {
    throw NSError(
      domain: "ChatEngine",
      code: Int(status),
      userInfo: [NSLocalizedDescriptionKey: "Secure random generation failed (\(status))"]
    )
  }
  return data
}

private func chatEngineEncryptHybridMessage(
  recipientPublicKeyPem: String,
  message: String,
  myPublicKeyPem: String?
) throws -> String {
  guard let recipientKey = chatEnginePublicKey(from: recipientPublicKeyPem) else {
    throw NSError(
      domain: "ChatEngine", code: 10,
      userInfo: [NSLocalizedDescriptionKey: "Invalid recipient public key"])
  }

  let aesKey = try chatEngineRandomBytes(count: 32)
  let iv = try chatEngineRandomBytes(count: 12)
  let nonce = try AES.GCM.Nonce(data: iv)
  let sealed = try AES.GCM.seal(Data(message.utf8), using: SymmetricKey(data: aesKey), nonce: nonce)

  guard let encryptedRecipientKey = chatEngineRSAEncryptOAEP(publicKey: recipientKey, plain: aesKey)
  else {
    throw NSError(
      domain: "ChatEngine", code: 11,
      userInfo: [NSLocalizedDescriptionKey: "Recipient RSA encrypt failed"])
  }

  var senderEncryptedKeyB64: String?
  if let myPublicKeyPem, let myPublicKey = chatEnginePublicKey(from: myPublicKeyPem) {
    if let encryptedSenderKey = chatEngineRSAEncryptOAEP(publicKey: myPublicKey, plain: aesKey) {
      senderEncryptedKeyB64 = encryptedSenderKey.base64EncodedString()
    }
  }

  let combinedCipher = sealed.ciphertext + sealed.tag
  var json: [String: Any] = [
    "v": 1,
    "iv": iv.base64EncodedString(),
    "c": combinedCipher.base64EncodedString(),
    "k": encryptedRecipientKey.base64EncodedString(),
  ]
  if let senderEncryptedKeyB64 { json["s"] = senderEncryptedKeyB64 }
  let serialized = try JSONSerialization.data(withJSONObject: json, options: [])
  guard let payloadString = String(data: serialized, encoding: .utf8) else {
    throw NSError(
      domain: "ChatEngine", code: 12,
      userInfo: [NSLocalizedDescriptionKey: "Could not encode payload"])
  }
  return payloadString
}

/// Identity shared by every `crypto` log line:
private func chatEngineCryptoMeta(chatId: String?, messageId: String?, isMine: Bool) -> [String:
  String]
{
  [
    "chat": chatId.map { String($0.prefix(12)) } ?? "-",
    "msg": messageId.map { String($0.suffix(12)) } ?? "-",
    "mine": isMine ? "Y" : "N",
  ]
}

private func chatEngineDecryptHybridMessage(
  privateKey: SecKey,
  ciphertext: String,
  isMyMessage: Bool,
  chatId: String? = nil,
  messageId: String? = nil
) -> String {
  var meta = chatEngineCryptoMeta(chatId: chatId, messageId: messageId, isMine: isMyMessage)
  meta["env"] = "hybrid"
  func fail(_ stage: String, _ extra: [String: String] = [:]) {
    var line = meta
    line["stage"] = stage
    for (key, value) in extra { line[key] = value }
    VibeLog.error("hybrid open failed", category: "crypto", metadata: line)
  }

  let trimmed = ciphertext.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
    fail("envelope-empty", ["bytes": String(ciphertext.count)])
    return ""
  }
  guard let payload = try? JSONDecoder().decode(ChatEngineHybridPayload.self, from: data) else {
    fail("json-decode", ["bytes": String(trimmed.count)])
    return ""
  }
  guard
    let iv = Data(base64Encoded: payload.iv),
    let cipherAndTag = Data(base64Encoded: payload.c),
    cipherAndTag.count >= 16
  else {
    fail(
      "envelope-shape",
      [
        "ivB64": String(payload.iv.count),
        "ctB64": String(payload.c.count),
      ])
    return ""
  }

  var keyCandidates = [Data]()

  if let g = payload.g, let gBlob = Data(base64Encoded: g) {
    keyCandidates.append(gBlob)
  }

  if isMyMessage {
    if let s = payload.s, let senderBlob = Data(base64Encoded: s) {
      keyCandidates.append(senderBlob)
    }
    if let k = payload.k, let recipientBlob = Data(base64Encoded: k) {
      keyCandidates.append(recipientBlob)
    }
  } else {
    if let k = payload.k, let recipientBlob = Data(base64Encoded: k) {
      keyCandidates.append(recipientBlob)
    }
    if let s = payload.s, let senderBlob = Data(base64Encoded: s) {
      keyCandidates.append(senderBlob)
    }
  }

  var aesKeyData: Data?
  for blob in keyCandidates {
    if let decrypted = chatEngineRSADecryptOAEP(privateKey: privateKey, encrypted: blob) {
      aesKeyData = decrypted
      break
    }
  }
  let slots =
    "\(payload.k != nil ? "k" : "")\(payload.s != nil ? "s" : "")\(payload.g != nil ? "g" : "")"
  guard let aesKeyData else {
    fail(
      "rsa-unwrap",
      [
        "cands": String(keyCandidates.count),
        "slots": slots.isEmpty ? "none" : slots,
      ])
    return ""
  }
  if aesKeyData.count != 32 {
    fail("aes-key-length", ["keyLen": String(aesKeyData.count), "slots": slots])
  }

  let ciphertextData = cipherAndTag.dropLast(16)
  let tagData = cipherAndTag.suffix(16)
  do {
    let nonce = try AES.GCM.Nonce(data: iv)
    let sealedBox = try AES.GCM.SealedBox(
      nonce: nonce,
      ciphertext: ciphertextData,
      tag: tagData
    )
    let plaintextData = try AES.GCM.open(sealedBox, using: SymmetricKey(data: aesKeyData))
    guard let plaintext = String(data: plaintextData, encoding: .utf8) else {
      fail("utf8", ["plainBytes": String(plaintextData.count)])
      return ""
    }
    if plaintext.isEmpty {
      fail("opened-empty", ["slots": slots])
      return ""
    }
    var okLine = meta
    okLine["stage"] = "ok"
    okLine["plainLen"] = String(plaintext.count)
    VibeLog.debug("hybrid opened", category: "crypto", metadata: okLine)
    return plaintext
  } catch {
    fail(
      "aes-gcm",
      [
        "reason": String(describing: error),
        "ctBytes": String(cipherAndTag.count),
        "slots": slots,
      ])
    return ""
  }
}

private func chatEngineEncryptMediaData(_ plainData: Data) throws -> (encryptedData: Data, keyBase64: String) {
  let aesKey = try chatEngineRandomBytes(count: 32)
  let iv = try chatEngineRandomBytes(count: 12)
  let nonce = try AES.GCM.Nonce(data: iv)
  let sealed = try AES.GCM.seal(plainData, using: SymmetricKey(data: aesKey), nonce: nonce)

  var combined = Data()
  combined.append(iv)
  combined.append(sealed.ciphertext)
  combined.append(sealed.tag)

  return (combined, aesKey.base64EncodedString())
}

private func chatEngineDecryptMediaData(_ encryptedData: Data, keyBase64: String) throws -> Data {
  guard
    let aesKey = Data(base64Encoded: keyBase64),
    encryptedData.count > 28
  else {
    throw NSError(
      domain: "ChatEngine",
      code: 40,
      userInfo: [NSLocalizedDescriptionKey: "Invalid encrypted media payload"]
    )
  }

  let iv = encryptedData.prefix(12)
  let ciphertext = encryptedData.dropFirst(12).dropLast(16)
  let tag = encryptedData.suffix(16)
  let nonce = try AES.GCM.Nonce(data: iv)
  let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
  return try AES.GCM.open(sealed, using: SymmetricKey(data: aesKey))
}

final class ChatEngine {
  static let shared = ChatEngine()
  static let didChangeNotification = Notification.Name("Vibe.ChatEngine.didChange")
  private static let bridgeSessionPageLimit = 40

  private struct SurfaceBinding: Equatable {
    let surfaceId: String
    let chatId: String?
    let myUserId: String?
    let peerUserId: String?
    let peerAgentId: String?
  }

  private struct AgentProgressState: Equatable {
    let label: String
    let tool: String?
    let status: String
    let updatedAtMs: Int64
  }

  struct AgentPreviewState {
    let image: UIImage
    let label: String
    let runId: String
    let agentUserId: String
    let updatedAtMs: Int64
  }

  struct AgentComputerState {
    let url: String
    let title: String
    let live: Bool
    let holder: String?
    let runId: String
    let agentUserId: String
    let updatedAtMs: Int64

    var host: String {
      let raw = URL(string: url)?.host ?? ""
      return raw.hasPrefix("www.") ? String(raw.dropFirst(4)) : raw
    }

    var isShell: Bool { url.isEmpty }

    var agentHoldsControl: Bool {
      let held = (holder ?? "").lowercased()
      return held.isEmpty || held == "agent"
    }
  }

  struct AgentApprovalMeta {
    let kind: String
    let tool: String
    let detail: String
    let risk: String
    let capability: String
    let scope: String
    let reason: String
  }

  private struct PendingCallSignal {
    let id: String
    let event: String
    let payload: [String: Any]
    let createdAtMs: Int
  }

  private let queue = DispatchQueue(label: "vibe.chat.engine")
  private static let syncWatchdogQueue = DispatchQueue(
    label: "vibe.chat.engine.sync-watchdog", qos: .utility)
  private let queueSpecificKey = DispatchSpecificKey<UInt8>()
  private let queueSpecificValue: UInt8 = 1
  private let store = ChatEngineStore.shared

  private var state: [String: Any] = [
    "state": "idle",
    "connected": false,
    "updatedAt": 0,
    "note": "ChatEngine scaffold (shadow mode)",
  ]
  private var journalEntryCount = 0
  private var onlineUsers = Set<String>()
  private var lastSeenByUserId: [String: Int64] = [:]
  private var surfaceBindings: [String: SurfaceBinding] = [:]
  private var openChatChannels: [String: Int] = [:]
  private var receiptIndex: [String: [String: String]] = [:]
  private var localStatusIndex: [String: [String: String]] = [:]
  private var phoenixClient: ChatRealtimeTransport?
  private var nativePresenceActive = false
  private var nativeUserTopic: String?
  private var nativeUserJoinRef: String?
  private var nativeSocketSignature: String?
  private var nativeChatJoinRefsByRef: [String: String] = [:]
  private var nativeJoinedChatIds = Set<String>()
  private var nativePendingMessagePushRefs: [String: (chatId: String, messageId: String)] = [:]
  private var nativeMessagePushSentAtMs: [String: Int] = [:]
  private var nativePendingEditPushRefs: [String: (chatId: String, messageId: String)] = [:]
  private var nativePendingDeletePushRefs: [
    String: (chatId: String, messageId: String, forEveryone: Bool)
  ] = [:]
  private var nativePendingCallSignals: [PendingCallSignal] = []
  private var nativePendingCallPushRefs: [String: String] = [:]
  private var nativeUserChannelDemandUntilMs = 0
  private var appIsForeground = true
  private var nwPathMonitor: NWPathMonitor?
  private let pathMonitorQueue = DispatchQueue(label: "com.vibegram.chat.pathmonitor")
  private var lastNetworkPathSatisfied = true
  private var pendingOutboundDraftsByMessageId: [String: [String: Any]] = [:]
  private var pendingOutboundQueueByChat: [String: [String]] = [:]
  private var outboundReplayWorkItemsByMessageId: [String: DispatchWorkItem] = [:]
  private var outboundReplayAttemptsByMessageId: [String: Int] = [:]
  private var directMlsReadinessInFlightChatIds = Set<String>()
  private var directMlsRetryWorkItemsByChat: [String: DispatchWorkItem] = [:]
  private var directMlsKeyRetryAttemptsByChat: [String: Int] = [:]
  private var directMlsConfirmationRetryAttemptsByChat: [String: Int] = [:]
  private static let directMlsKeyRetryDelays: [TimeInterval] = [3, 15, 30, 90, 240, 480]
  private static let directMlsConfirmationRetryDelays: [TimeInterval] = [1, 2, 4, 8, 15]
  private var packetRuntimeStartInFlight = false
  private var activeMediaUploadTasksByMessageId: [String: URLSessionTask] = [:]
  private var canceledOutboundMessageIds = Set<String>()
  private var nativeTypingStateByChatId: [String: Bool] = [:]
  private var nativeTypingSentAtMsByChatId: [String: Int64] = [:]
  static let typingRefreshMs: Int64 = 3500
  private var peerTypingUserIdsByChatId: [String: Set<String>] = [:]
  private var peerTypingSeenAtMsByChatId: [String: [String: Int64]] = [:]
  private var peerTypingExpiryScheduled = false
  static let peerTypingExpiryMs: Int64 = 6500

  let uiMirror = ChatEngineUIMirror()

  let homePreviewMemo = ChatEngineHomePreviewMemo()
  private var agentProgressByChatId: [String: AgentProgressState] = [:]
  private var agentTurnRunningAtMsByChatId: [String: Int64] = [:]
  private static let agentTurnRunningGraceMs: Int64 = 12_000
  private var activeIsolatedRunIdByChatId: [String: String] = [:]
  private var latestAgentPreviewByChatId: [String: AgentPreviewState] = [:]
  private static let agentComputerLock = NSLock()
  private static var agentComputerByChatId: [String: AgentComputerState] = [:]
  private static var agentApprovalMetaByMessageId: [String: AgentApprovalMeta] = [:]
  private var bridgeSettledSessionSigByChatId: [String: [String: String]] = [:]
  private var lastIngestedBridgeSessionSigByChatId: [String: String] = [:]
  private var agentStreamTimestampsByChat: [String: [String: Int64]] = [:]
  private var agentSettleSlotTsByMessageId: [String: Int64] = [:]
  private var agentSettleSlotTsOrder: [String] = []
  private var lanProgressSeqByTask: [String: Int] = [:]
  private var lanProgressLinesByTask: [String: [String]] = [:]
  private var cloudProgressAtMsByTask: [String: Int64] = [:]
  private static let lanReclaimAfterCloudSilenceMs: Int64 = 60000

  private var liveStreamTaskRowIdByChatId: [String: [String: String]] = [:]
  private var retiredAgentTaskIdsByChatId: [String: [String: Int64]] = [:]
  private static let retiredAgentTaskTtlMs: Int64 = 15 * 60 * 1000
  private var pendingTeamWorkersStatusByChatId: [String: [String: [[String: Any]]]] = [:]
  private var teamWorkerProgressNodesByChatId: [String: [String: [String: [[String: Any]]]]] = [:]
  private var agentBridgeHistoryByChat: [String: [String: Any]] = [:]
  private var agentBridgeHistoryListByChatProvider: [String: [String: Any]] = [:]
  private var lanHistoryPendingRequestIds: Set<String> = []
  private var pendingAgentBridgeHistoryRequestsByChat: [String: [[String: Any]]] = [:]
  private var agentBridgeFileByRequestId: [String: [String: Any]] = [:]
  private var agentBridgeUsageByRequestId: [String: [String: Any]] = [:]
  private var agentBridgeUsageByChatProvider: [String: [String: Any]] = [:]
  private var volatileBridgeRowsStoreTimers: [String: DispatchWorkItem] = [:]
  private var volatileBridgeRowsRestoredChats: Set<String> = []
  private var agentBridgeAskByRequestId: [String: [String: Any]] = [:]
  private var presentedAskRequestIds: Set<String> = []
  private var pendingBridgeSessionIngestByRequestId: [String: (chatId: String, provider: String)] = [:]
  private var liveBridgeSessionIngestByChatId: [String: (provider: String, sessionId: String, requestId: String)] = [:]
  private var lastBridgeRearmAtMsByChatId: [String: Int64] = [:]
  private var currentSessionLoadInflightByChatId: [String: (requestId: String, atMs: Int64)] = [:]
  private var noCurrentSessionUntilMsByChatId: [String: Int64] = [:]
  private var sessionLoadInflightByChatId: [String: (sessionId: String, requestId: String, atMs: Int64)] = [:]
  private var bridgeSessionPagingByChatId: [String: (
    provider: String, sessionId: String, nextBefore: String?, hasMoreBefore: Bool, loadingOlder: Bool
  )] = [:]
  private var bridgeSessionTopicByChatId: [String: String] = [:]
  private var nativeRecordingStateByChatId: [String: Bool] = [:]
  private var pinnedMessagesByChatId: [String: [[String: Any]]] = [:]
  private var pinnedFetchInFlightChatIds = Set<String>()
  private var historyRowsByChat: [String: [[String: Any]]] = [:]
  private var chatIngestGenerationByChat: [String: Int] = [:]
  private var historyFullyLoadedChats = Set<String>()
  private var historyRowsRestoredFromCacheChats = Set<String>()
  private var historyLastNetworkSyncAtByChat: [String: Int] = [:]
  private let historyRevalidationTTLMs: Int = 20 * 60 * 1000
  private var historyRestoreMissChats = Set<String>()
  private var agentDMChatIdsPersisted = Set<String>()
  private var agentDMChatIdsLoaded = false
  private var agentDMStorePurgedChats = Set<String>()
  private static let agentDMChatIdsDefaultsKey = "VibeAgentDMChatIds"
  private var cachedSavedMessagesResponse: [[String: Any]]?
  private var savedReactionGenerationByMessageId: [String: UInt64] = [:]
  private var historyLoadingChats = Set<String>()
  private var historyOlderExhaustedChats = Set<String>()
  private var historyLoadingOlderChats = Set<String>()
  private var historyBackfillingChats = Set<String>()
  private var historyBackfillAtMsByChat: [String: Int64] = [:]
  private var historyHasMoreByChat: [String: Bool] = [:]
  private var historyNextCursorByChat: [String: String] = [:]
  private var historyNextCursorBoundaryByChat: [String: (messageId: String, timestampMs: Int64)] =
    [:]
  private let nativeCallSignalDemandMs = 60_000
  private let nativeCallSignalMaxAgeMs = 45_000
  private var liveMessageRowsByChat: [String: [String: [String: Any]]] = [:]
  private var deletedMessageIdsByChat: [String: Set<String>] = [:]
  private var chatPeerUserIdsByChatId: [String: String] = [:]
  private var chatPeerAgentIdsByChatId: [String: String] = [:]
  private var agentIdsByPeerUserId: [String: String] = [:]
  private var friendPublicKeysByUserId: [String: String] = [:]

  private var mlsProvisionedAtMs: Int64 = 0
  private var pendingFriendKeyChatIdsByUserId: [String: Set<String>] = [:]
  private var friendKeyFetchInFlightUserIds = Set<String>()
  private var friendKeyRetryWorkItemsByUserId: [String: DispatchWorkItem] = [:]
  private var configuredUserId: String?
  private var reconnectWorkItem: DispatchWorkItem?
  private var reconnectAttempt: Int = 0
  private var autoReconnectEnabled = true
  private var cachedDecryptPrivateKeyPem: String?
  private var cachedDecryptPrivateKey: SecKey?
  private var cachedDecryptKeyTimestamp: Date?
  private static let fallbackApiBaseURL = "https://api.vibegram.io"
  private let nativeConnectStaleTimeoutMs = 5_000
  private let queuedOutboundVisibleErrorDelayMs = 20_000
  private let outboundReplayDelays: [TimeInterval] = [0.45, 0.9, 1.8, 3.5, 6.0, 10.0]
  private let bridgeQueuedReplayMaxAgeMs = 120_000
  private let keyTTL: TimeInterval = 300
  private let chatHistoryCacheKeyPrefix = "vibe.ios.chatHistory.rows.v1"
  private let chatHistoryFetchLimit = 100
  private let chatOlderHistoryFetchLimit = 2_000
  private let chatHistoryCacheRowLimit = 2_000
  private let messageStore = ChatMessageStore()

  private init() {
    queue.setSpecific(key: queueSpecificKey, value: queueSpecificValue)
    queue.async { [weak self] in
      guard let self else { return }
      self.publishBridgeSessionIds()
      self.publishStatus(self.statusSnapshotLocked())
    }
    NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      self?.clearCachedKeyOnBackground()
    }
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      self.queue.async {
        self.appIsForeground = true
        self.ensureNativeTransportIfDemandedLocked(trigger: "app_active")
      }
    }
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
    ) { [weak self] _ in
      self?.queue.async { self?.appIsForeground = false }
    }
    NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      self?.reconnectOnForeground()
    }
    startNetworkPathMonitor()
    queue.async { [weak self] in
      self?.restoreOutboundStateLocked()
      self?.purgeVolatileBridgeRowsCacheOnLaunchLocked()
    }
    DispatchQueue.global(qos: .utility).async { [weak self] in
      self?.ensureNativeTransport(trigger: "engine_init")
    }
  }

  func peerUserId(chatId: String) -> String? {
    syncOnQueue { chatPeerUserIdsByChatId[chatId] }
  }

  private func currentOutboundUserIdLocked() -> String? {
    normalizedString(store.getConfig()["userId"])
  }

  private func bridgeProviderForOutboundDraftLocked(_ draft: [String: Any], fallbackChatId: String? = nil) -> String? {
    let metadata = draft["metadata"] as? [String: Any] ?? [:]
    let chatId =
      normalizedString(draft["chatId"] ?? draft["chat_id"])
      ?? normalizedString(fallbackChatId)
    let peerUserId = normalizedString(draft["peerUserId"] ?? draft["peer_user_id"])
    let peerAgentId =
      normalizedString(
        draft["peerAgentId"] ?? draft["peer_agent_id"] ?? draft["mentionedAgentId"]
          ?? draft["mentioned_agent_id"])
    return bridgeProviderForChatLocked(
      chatId: chatId,
      peerUserId: peerUserId,
      peerAgentId: peerAgentId,
      metadata: metadata
    )
  }

  private func persistOutboundStateLocked() {
    guard let userId = currentOutboundUserIdLocked() else { return }
    let persistedDrafts = pendingOutboundDraftsByMessageId.filter { _, draft in
      guard bridgeProviderForOutboundDraftLocked(draft) == nil else { return false }
      let chatId = normalizedString(draft["chatId"] ?? draft["chat_id"])
      return !isBuiltInAgentChatId(chatId)
    }
    var persistedQueues: [String: [String]] = [:]
    for (chatId, ids) in pendingOutboundQueueByChat {
      if isBuiltInAgentChatId(chatId) || isVolatileBridgeAgentChatLocked(chatId: chatId) {
        continue
      }
      let keptIds = ids.filter { persistedDrafts[$0] != nil }
      if !keptIds.isEmpty { persistedQueues[chatId] = keptIds }
    }
    if persistedDrafts.isEmpty && persistedQueues.isEmpty {
      store.clearOutboundState()
      return
    }
    store.setOutboundState([
      "userId": userId,
      "updatedAt": nowMs(),
      "draftsByMessageId": persistedDrafts,
      "queueByChat": persistedQueues,
    ])
  }

  private func restoreOutboundStateLocked() {
    guard pendingOutboundDraftsByMessageId.isEmpty, pendingOutboundQueueByChat.isEmpty else { return }
    let payload = store.getOutboundState()
    guard !payload.isEmpty else { return }
    guard let storedUserId = normalizedString(payload["userId"]) else { return }
    guard let currentUserId = currentOutboundUserIdLocked(), currentUserId == storedUserId else {
      store.clearOutboundState()
      return
    }

    let rawDrafts = payload["draftsByMessageId"] as? [String: Any] ?? [:]
    var restoredDrafts: [String: [String: Any]] = [:]
    var skippedBridgeDrafts = 0
    for (messageId, value) in rawDrafts {
      if let draft = value as? [String: Any] {
        if bridgeProviderForOutboundDraftLocked(draft) != nil {
          skippedBridgeDrafts += 1
          continue
        }
        let draftChatId = normalizedString(draft["chatId"] ?? draft["chat_id"])
        if isBuiltInAgentChatId(draftChatId) {
          skippedBridgeDrafts += 1
          continue
        }
        restoredDrafts[messageId] = draft
      }
    }

    let rawQueues = payload["queueByChat"] as? [String: Any] ?? [:]
    var restoredQueues: [String: [String]] = [:]
    var healedFanOutDrafts = 0
    for (chatId, value) in rawQueues {
      if let ids = value as? [String], !ids.isEmpty {
        if isBuiltInAgentChatId(chatId) || isVolatileBridgeAgentChatLocked(chatId: chatId) {
          skippedBridgeDrafts += ids.count
          continue
        }
        var keptIds = ids.filter { restoredDrafts[$0] != nil }
        if keptIds.count > Self.maxHealedOutboundQueue {
          let dropped = keptIds.count - Self.maxHealedOutboundQueue
          let survivors = Array(keptIds.prefix(Self.maxHealedOutboundQueue))
          for id in keptIds.dropFirst(Self.maxHealedOutboundQueue) {
            restoredDrafts.removeValue(forKey: id)
            upsertLocalStatusLocked(chatId: chatId, messageId: id, status: "error")
          }
          keptIds = survivors
          healedFanOutDrafts += dropped
          NSLog(
            "[ChatEngine] restoreOutboundState HEALED chatId=%@ dropped=%d kept=%d — queue was a replay fan-out, not a backlog",
            String(chatId.prefix(12)), dropped, keptIds.count)
        }
        if !keptIds.isEmpty { restoredQueues[chatId] = keptIds }
      }
    }

    pendingOutboundDraftsByMessageId = restoredDrafts
    pendingOutboundQueueByChat = restoredQueues
    if healedFanOutDrafts > 0 {
      appendJournalLocked(
        event: "native-outgoing-restore-healed",
        payload: ["dropped": healedFanOutDrafts])
      persistOutboundStateLocked()
    }
    if skippedBridgeDrafts > 0 {
      appendJournalLocked(
        event: "native-bridge-outgoing-restore-skip",
        payload: ["drafts": skippedBridgeDrafts]
      )
      persistOutboundStateLocked()
    }
    if !restoredDrafts.isEmpty || !restoredQueues.isEmpty {
      appendJournalLocked(
        event: "native-outgoing-restored",
        payload: ["drafts": restoredDrafts.count, "chats": restoredQueues.count]
      )
    }
  }

  private func dropQueuedOutboundForChatLocked(chatId: String, reason: String) {
    let ids = pendingOutboundQueueByChat.removeValue(forKey: chatId) ?? []
    guard !ids.isEmpty else { return }
    for id in ids {
      pendingOutboundDraftsByMessageId.removeValue(forKey: id)
      removeMessageIndicesLocked(chatId: chatId, messageId: id)
      markLiveMessageDeletedLocked(chatId: chatId, messageId: id)
    }
    persistOutboundStateLocked()
    appendJournalLocked(
      event: "native-bridge-outgoing-drop-queue",
      payload: ["chatId": chatId, "count": ids.count, "reason": reason]
    )
    postChatDeltaLocked(
      chatId: chatId, inserted: [], updated: [], deleted: ids, source: "delete")
  }

  private func markVolatileBridgeSendErrorLocked(
    chatId: String,
    messageId: String,
    reason: String,
    provider: String?
  ) {
    removeQueuedOutboundDraftLocked(chatId: chatId, messageId: messageId, dropDraft: false)
    nativePendingMessagePushRefs = nativePendingMessagePushRefs.filter { _, pending in
      !(pending.chatId == chatId && pending.messageId == messageId)
    }
    setLiveMessageUploadProgressLocked(chatId: chatId, messageId: messageId, progress: nil)
    upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
    appendJournalLocked(
      event: "native-bridge-send-failed",
      payload: [
        "chatId": chatId,
        "messageId": messageId,
        "provider": provider ?? "",
        "reason": reason,
        "rowKept": true,
      ]
    )
    let displayProvider = provider.map { $0.capitalized } ?? "Bridge"
    let snapshot = statusSnapshotLocked()
    postChangeLocked(
      reason: "messageStatusChanged",
      userInfo: [
        "chatId": chatId,
        "messageId": messageId,
        "status": "error",
        "state": snapshot,
      ])
    postChangeLocked(
      reason: "engineError",
      userInfo: [
        "chatId": chatId,
        "messageId": messageId,
        "category": "bridgeSendFailed",
        "provider": provider ?? "",
        "reason": reason,
        "error": "\(displayProvider) message did not reach the bridge. Tap it to retry.",
        "state": snapshot,
      ])
  }

  private func clearCachedKeyOnBackground() {
    queue.async {
      self.cachedDecryptPrivateKey = nil
      self.cachedDecryptPrivateKeyPem = nil
      self.cachedDecryptKeyTimestamp = nil
    }
  }

  private func reconnectOnForeground() {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      self.syncOnQueue {
        self.reconnectAttempt = 0
        self.cancelReconnectLocked()
        self.appendJournalLocked(
          event: "foreground-reconnect",
          payload: ["state": self.normalizedString(self.state["state"]) ?? "unknown"])
      }
      self.ensureNativeTransport(trigger: "app_foreground")
    }
  }

  private func startNetworkPathMonitor() {
    guard #available(iOS 13.0, *) else { return }
    guard nwPathMonitor == nil else { return }
    let monitor = NWPathMonitor()
    nwPathMonitor = monitor
    monitor.pathUpdateHandler = { [weak self] path in
      self?.handleNetworkPathUpdate(satisfied: path.status == .satisfied)
    }
    monitor.start(queue: pathMonitorQueue)
  }

  private func handleNetworkPathUpdate(satisfied: Bool) {
    queue.async { [weak self] in
      guard let self else { return }
      let previouslySatisfied = self.lastNetworkPathSatisfied
      guard satisfied != previouslySatisfied else { return }
      self.lastNetworkPathSatisfied = satisfied

      if !satisfied {
        let currentState = self.normalizedString(self.state["state"])?.lowercased() ?? ""
        let liveish =
          (self.state["connected"] as? Bool) == true
          || currentState == "native-socket-open"
          || currentState == "connecting-native-presence"
        NSLog("[ChatEngine] network path lost — liveSocket=%@", liveish ? "Y" : "N")
        if liveish {
          self.handleNativeSocketError("network path unsatisfied")
        }
        return
      }

      let connected = (self.state["connected"] as? Bool) == true
      NSLog(
        "[ChatEngine] network path restored — kicking reconnect (wasConnected=%@)",
        connected ? "Y" : "N")
      self.appendJournalLocked(event: "network-path-restored", payload: ["connected": connected])
      self.reconnectAttempt = 0
      self.cancelReconnectLocked()
      self.ensureNativeTransportIfDemandedLocked(trigger: "network_restored")
    }
  }

  private func loadNativeAuthSessionFromKeychain() -> [String: Any]? {
    let keyData = Data("user_session_v2".utf8)

    for service in ["app:no-auth", "app:auth", "app"] {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: keyData,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var result: AnyObject?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecSuccess, let data = result as? Data,
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      {
        return json
      }
    }

    let legacyQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: "user_session_v2",
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(legacyQuery as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data {
      return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    return nil
  }

  private func hasNativeSocketConfigLocked() -> Bool {
    let config = store.getConfig()
    let transportMode = transportModeLocked(config: config)
    let socketUrl = normalizedString(config["socketUrl"] ?? config["url"])
    let userId = normalizedString(config["userId"])
    let token = normalizedString(config["authToken"] ?? config["token"])
    if transportMode == "offline" {
      return userId != nil && token != nil
    }
    if transportMode == "bridge_text" {
      return bridgeBaseURLLocked(config: config) != nil && userId != nil && token != nil
    }
    return socketUrl != nil && userId != nil && token != nil && token != userId
  }

  @discardableResult
  private func bootstrapConfigFromNativeSessionIfNeededLocked(trigger: String) -> Bool {
    if hasNativeSocketConfigLocked() { return true }

    let existing = store.getConfig()
    let nativeCallConfig = VibeNativeCallStore.shared.getNativeEngineConfig()
    let session = loadNativeAuthSessionFromKeychain()

    guard
      let userId = normalizedString(
        existing["userId"] ?? nativeCallConfig["userId"] ?? session?["userId"])
    else {
      appendJournalLocked(
        event: "native-config-bootstrap-skip",
        payload: [
          "trigger": trigger,
          "reason": "missing_user_id",
        ])
      return false
    }

    let apiBase =
      normalizedString(
        existing["apiBaseUrl"] ?? existing["baseUrl"] ?? nativeCallConfig["baseUrl"]
          ?? nativeCallConfig["apiBaseUrl"])
      ?? Self.fallbackApiBaseURL
    let socketUrl =
      normalizedString(existing["socketUrl"] ?? existing["url"] ?? nativeCallConfig["socketUrl"])
      ?? (apiBase.replacingOccurrences(of: "^http", with: "ws", options: .regularExpression)
        + "/socket")
    let token = [
      normalizedString(session?["loginToken"]),
      normalizedString(nativeCallConfig["authToken"]),
      normalizedString(existing["authToken"] ?? existing["token"]),
    ].compactMap { $0 }.first { $0 != userId && $0.lowercased() != "undefined" }
    guard let token else {
      appendJournalLocked(
        event: "native-config-bootstrap-skip",
        payload: ["trigger": trigger, "reason": "missing_login_token"])
      return false
    }

    var merged = existing
    merged["apiBaseUrl"] = apiBase
    merged["socketUrl"] = socketUrl
    merged["authToken"] = token
    merged["userId"] = userId
    if normalizedString(existing["userChannelTopic"]) == nil {
      merged["userChannelTopic"] = "user:\(userId)"
    }
    if normalizedString(existing["privateKeyPem"] ?? existing["privateKey"]) == nil,
      let privateKeyPem = normalizedString(session?["privateKeyPem"] ?? session?["privateKey"])
    {
      merged["privateKeyPem"] = privateKeyPem
    }
    if normalizedString(existing["publicKeyPem"] ?? existing["publicKey"]) == nil,
      let publicKeyPem = normalizedString(session?["publicKeyPem"] ?? session?["publicKey"])
    {
      merged["publicKeyPem"] = publicKeyPem
    }

    store.setConfig(merged)
    state["state"] = "configured-native-bootstrap"
    state["updatedAt"] = nowMs()
    state["configuredAt"] = state["updatedAt"]
    state["configKeys"] = Array(merged.keys).sorted()
    state["note"] = "ChatEngine configured from native session"
    state["presenceSource"] = nativePresenceActive ? "native" : "shadow"
    appendJournalLocked(
      event: "native-config-bootstrap",
      payload: [
        "trigger": trigger,
        "hasSocketUrl": normalizedString(merged["socketUrl"] ?? merged["url"]) != nil,
        "hasUserId": normalizedString(merged["userId"]) != nil,
        "hasToken": normalizedString(merged["authToken"] ?? merged["token"]) != nil,
        "hasPrivateKey": normalizedString(merged["privateKeyPem"] ?? merged["privateKey"]) != nil,
        "hasPublicKey": normalizedString(merged["publicKeyPem"] ?? merged["publicKey"]) != nil,
      ])
    return true
  }

  private func ensureNativeTransportIfDemandedLocked(trigger: String) {
    guard hasRealtimeDemandLocked() else { return }
    DispatchQueue.global(qos: .utility).async { [weak self] in
      self?.ensureNativeTransport(trigger: trigger)
    }
  }

  private func ensureNativeTransport(trigger: String) {
    guard #available(iOS 13.0, *) else { return }
    var clientToDisconnect: ChatRealtimeTransport?
    let shouldConnect = syncOnQueue {
      if !hasRealtimeDemandLocked() {
        return false
      }
      autoReconnectEnabled = true
      let connected = (state["connected"] as? Bool) == true
      var currentState = normalizedString(state["state"])?.lowercased() ?? ""
      let now = nowMs()
      let updatedAt = parseLongValue(state["updatedAt"]) ?? 0
      let stateAge = updatedAt > 0 ? now - Int(updatedAt) : -1
      if currentState == "connecting-native-presence" && stateAge >= nativeConnectStaleTimeoutMs {
        NSLog(
          "[ChatEngine] ensureNativeTransport resetting stale connect trigger=%@ stateAgeMs=%d hasClient=%@",
          trigger,
          stateAge,
          phoenixClient == nil ? "N" : "Y"
        )
        clientToDisconnect = phoenixClient
        phoenixClient = nil
        nativeSocketSignature = nil
        nativePresenceActive = false
        nativeUserJoinRef = nil
        nativeUserTopic = nil
        nativeChatJoinRefsByRef.removeAll()
        nativeJoinedChatIds.removeAll()
        nativePendingMessagePushRefs.removeAll()
        nativePendingEditPushRefs.removeAll()
        nativePendingDeletePushRefs.removeAll()
        nativePendingCallPushRefs.removeAll()
        nativeTypingStateByChatId.removeAll()
        peerTypingUserIdsByChatId.removeAll()
        agentProgressByChatId.removeAll()
        nativeRecordingStateByChatId.removeAll()
        pinnedFetchInFlightChatIds.removeAll()
        historyLoadingChats.removeAll()
        state["connected"] = false
        state["state"] = "native-connect-stale"
        state["updatedAt"] = now
        state["presenceSource"] = "shadow"
        appendJournalLocked(
          event: "native-connect-stale-reset",
          payload: ["trigger": trigger, "stateAgeMs": stateAge]
        )
        postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": statusSnapshotLocked()])
        currentState = "native-connect-stale"
      }
      if connected || currentState == "connecting-native-presence"
        || currentState == "native-socket-open"
      {
        return false
      }
      if transportModeLocked() == "offline" {
        return false
      }
      return bootstrapConfigFromNativeSessionIfNeededLocked(trigger: trigger)
    }
    clientToDisconnect?.disconnect()
    guard shouldConnect else { return }
    _ = connectNativePresence()
  }

  @discardableResult
  private func ensurePacketRuntimeAsync(trigger: String) -> Bool {
    var shouldStart = false
    var handled = false
    syncOnQueue { () -> Void in
      let config = store.getConfig()
      guard packetProxyEnabledLocked(config: config),
        packetProxyPortLocked(config: config) == nil
      else { return }
      handled = true
      guard !packetRuntimeStartInFlight else { return }
      packetRuntimeStartInFlight = true
      shouldStart = true
      state["state"] = "starting-proxy"
      state["connected"] = false
      state["updatedAt"] = nowMs()
      state["note"] = "Starting the proxy for the chat transport"
      appendJournalLocked(event: "packet-runtime-start", payload: ["trigger": trigger])
      postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": statusSnapshotLocked()])
    }

    guard handled else { return false }
    guard shouldStart else { return true }

    Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
      do {
        let snapshot = try PacketRuntime.shared.ensureStarted()
        self.queue.async {
          self.packetRuntimeStartInFlight = false
          self.state["state"] = "proxy-ready"
          self.state["connected"] = false
          self.state["updatedAt"] = self.nowMs()
          self.state["note"] = "Proxy ready for the chat transport"
          self.state["packetProxyPort"] = snapshot.proxyPort
          self.appendJournalLocked(
            event: "packet-runtime-ready",
            payload: [
              "trigger": trigger,
              "proxyHost": snapshot.proxyHost,
              "proxyPort": snapshot.proxyPort,
            ]
          )
          self.postChangeLocked(
            reason: "connectionStateChanged",
            userInfo: ["state": self.statusSnapshotLocked()]
          )
        }
        self.ensureNativeTransport(trigger: "packet_runtime_ready:\(trigger)")
        let queuedChatIds = self.syncOnQueue { Array(self.pendingOutboundQueueByChat.keys) }
        for chatId in queuedChatIds {
          self.queue.async {
            self.scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "packet_runtime_ready")
          }
        }
      } catch {
        let errorText = error.localizedDescription
        NSLog("[ChatEngine] proxy start failed trigger=%@ error=%@", trigger, errorText)
        self.store.updateConfig([
          "packetStatus": "failed",
          "packetProxyPort": nil,
          "packetLastError": errorText,
        ])
        self.queue.async {
          self.packetRuntimeStartInFlight = false
          self.state["state"] = "proxy-unavailable"
          self.state["connected"] = false
          self.state["updatedAt"] = self.nowMs()
          self.state["note"] = "Proxy is on but did not start; chat stays offline"
          self.appendJournalLocked(
            event: "packet-runtime-failed",
            payload: ["trigger": trigger, "error": String(errorText.prefix(180))]
          )
          self.postChangeLocked(
            reason: "connectionStateChanged",
            userInfo: ["state": self.statusSnapshotLocked()]
          )
        }
      }
    }
    return true
  }

  private func chatNeedsRealtimeLocked(_ rawChatId: String?) -> Bool {
    guard let chatId = normalizedString(rawChatId), !chatId.isEmpty else {
      return true
    }
    return chatId != "saved_messages" && !isBuiltInAgentChatId(chatId)
  }

  private func isBuiltInAgentChatId(_ rawChatId: String?) -> Bool {
    guard let chatId = normalizedString(rawChatId)?.lowercased() else { return false }
    switch chatId {
    case "vibe_agent", "vibeagent", "vibe-ai", "vibe_ai":
      return true
    default:
      return false
    }
  }

  private func hasRealtimeDemandLocked() -> Bool {
    if appIsForeground, normalizedString(getConfigValueLocked("userId")) != nil {
      return true
    }
    if nativeUserChannelDemandUntilMs > nowMs() {
      return true
    }
    if pendingOutboundQueueByChat.keys.contains(where: { chatNeedsRealtimeLocked($0) }) {
      return true
    }
    if openChatChannels.keys.contains(where: { chatNeedsRealtimeLocked($0) }) {
      return true
    }
    if surfaceBindings.values.contains(where: { binding in
      chatNeedsRealtimeLocked(binding.chatId)
    }) {
      return true
    }
    return false
  }

  private func cancelReconnectLocked() {
    reconnectWorkItem?.cancel()
    reconnectWorkItem = nil
  }

  private func reconnectDelayLocked() -> TimeInterval {
    let hasPendingOutbound = !pendingOutboundQueueByChat.isEmpty
    let sequence: [TimeInterval] =
      hasPendingOutbound
      ? [0.15, 0.35, 0.75, 1.5, 2.5, 4.0]
      : [0.35, 0.9, 2.0, 4.0, 6.0, 8.0]
    let index = min(max(0, reconnectAttempt), sequence.count - 1)
    return sequence[index]
  }

  private func scheduleReconnectLocked(reason: String) {
    guard #available(iOS 13.0, *) else { return }
    guard autoReconnectEnabled else { return }
    guard hasRealtimeDemandLocked() else { return }
    guard reconnectWorkItem == nil else { return }
    let connected = (state["connected"] as? Bool) == true
    let currentState = normalizedString(state["state"])?.lowercased() ?? ""
    guard !connected, currentState != "connecting-native-presence",
      currentState != "native-socket-open"
    else { return }

    let delay = reconnectDelayLocked()
    appendJournalLocked(
      event: "native-reconnect-scheduled",
      payload: [
        "reason": reason,
        "attempt": reconnectAttempt + 1,
        "delayMs": Int(delay * 1000),
      ])

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.queue.async {
        self.reconnectWorkItem = nil
        guard self.autoReconnectEnabled else { return }
        let connected = (self.state["connected"] as? Bool) == true
        let currentState = self.normalizedString(self.state["state"])?.lowercased() ?? ""
        guard !connected, currentState != "connecting-native-presence",
          currentState != "native-socket-open"
        else {
          self.reconnectAttempt = 0
          return
        }
        self.reconnectAttempt = min(self.reconnectAttempt + 1, 64)
        self.appendJournalLocked(
          event: "native-reconnect-attempt",
          payload: [
            "attempt": self.reconnectAttempt,
            "state": currentState,
          ])
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "auto_reconnect")
        }
      }
    }

    reconnectWorkItem = workItem
    queue.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  func configure(_ payload: [String: Any]) -> [String: Any] {
    let existingPayload = store.getConfig()
    let nextUserId = normalizedString(payload["userId"])
    let existingUserId = normalizedString(existingPayload["userId"])
    let mergedPayload: [String: Any] =
      !existingPayload.isEmpty && (existingUserId == nil || existingUserId == nextUserId)
      ? existingPayload.merging(payload) { _, new in new }
      : payload
    store.setConfig(mergedPayload)
    let now = nowMs()
    let snapshot = syncOnQueue {
      if configuredUserId != nil, configuredUserId != nextUserId {
        outboundReplayWorkItemsByMessageId.values.forEach { $0.cancel() }
        outboundReplayWorkItemsByMessageId.removeAll()
        outboundReplayAttemptsByMessageId.removeAll()
        directMlsRetryWorkItemsByChat.values.forEach { $0.cancel() }
        directMlsRetryWorkItemsByChat.removeAll()
        directMlsReadinessInFlightChatIds.removeAll()
        directMlsKeyRetryAttemptsByChat.removeAll()
        directMlsConfirmationRetryAttemptsByChat.removeAll()
        pendingOutboundDraftsByMessageId.removeAll()
        pendingOutboundQueueByChat.removeAll()
        store.clearOutboundState()
      }
      configuredUserId = nextUserId
      restoreOutboundStateLocked()
      state["state"] = "configured"
      state["updatedAt"] = now
      state["configuredAt"] = now
      state["configKeys"] = Array(mergedPayload.keys).sorted()
      state["note"] =
        "ChatEngine configured (native Phoenix presence enabled, shadow fallback active)"
      state["presenceSource"] = nativePresenceActive ? "native" : "shadow"
      let snapshot = statusSnapshotLocked()
      appendJournalLocked(event: "configure", payload: ["keys": Array(mergedPayload.keys).sorted()])
      for chatId in openChatChannels.keys {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
      }
      postChangeLocked(reason: "configure", userInfo: ["state": snapshot])
      return snapshot
    }
    ensureNativeTransport(trigger: "configure")
    return snapshot
  }

  private let publishedStatusLock = NSLock()
  private var publishedStatus: [String: Any]?

  func getStatus() -> [String: Any] {
    if Thread.isMainThread {
      publishedStatusLock.lock()
      let published = publishedStatus
      publishedStatusLock.unlock()
      if let published {
        queue.async { [weak self] in
          guard let self else { return }
          self.publishStatus(self.statusSnapshotLocked())
        }
        return published
      }
    }
    return syncOnQueue {
      let snapshot = statusSnapshotLocked()
      publishStatus(snapshot)
      return snapshot
    }
  }

  func getTransportStatus() -> [String: Any] {
    getStatus()
  }

  func status(_ completion: @escaping ([String: Any]) -> Void) {
    publishedStatusLock.lock()
    let published = publishedStatus
    publishedStatusLock.unlock()
    if let published {
      queue.async { [weak self] in
        guard let self else { return }
        self.publishStatus(self.statusSnapshotLocked())
      }
      if Thread.isMainThread {
        completion(published)
      } else {
        DispatchQueue.main.async { completion(published) }
      }
      return
    }
    queue.async { [weak self] in
      guard let self else { return }
      let snapshot = self.statusSnapshotLocked()
      self.publishStatus(snapshot)
      DispatchQueue.main.async { completion(snapshot) }
    }
  }

  private func publishStatus(_ snapshot: [String: Any]) {
    publishedStatusLock.lock()
    publishedStatus = snapshot
    publishedStatusLock.unlock()
  }

  func resolveURLForOpen(_ raw: String?) -> String? {
    syncOnQueue { resolveURLForOpenLocked(raw) }
  }

  func authorizationHeaderForAPI() -> String? {
    guard let token = authHeaderTokenLocked(), !token.isEmpty else { return nil }
    return "Bearer \(token)"
  }

  func authorizationHeaderForRemoteURL(_ url: URL) -> String? {
    guard let host = url.host?.lowercased(),
      host == "vibegram.io" || host.hasSuffix(".vibegram.io")
    else { return nil }
    return authorizationHeaderForAPI()
  }

  func decryptMediaDataIfNeeded(_ data: Data, mediaKey: String?) -> Data? {
    let trimmedKey = mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmedKey.isEmpty else { return data }
    return try? chatEngineDecryptMediaData(data, keyBase64: trimmedKey)
  }

  func isUserOnline(userId: String?) -> Bool {
    guard let normalized = normalizedUpper(userId), !normalized.isEmpty else { return false }
    if let published = uiMirror.isUserOnline(userId: normalized) { return published }
    return syncOnQueue { onlineUsers.contains(normalized) }
  }

  func lastSeenTimestampMs(userId: String?) -> Int64? {
    guard let normalized = normalizedUpper(userId), !normalized.isEmpty else { return nil }
    if let published = uiMirror.lastSeenTimestampMs(userId: normalized) { return published }
    return syncOnQueue { lastSeenByUserId[normalized] }
  }

  func connect() -> [String: Any] {
    if #available(iOS 13.0, *) {
      syncOnQueue {
        autoReconnectEnabled = true
        cancelReconnectLocked()
      }
      return connectNativePresence()
    }
    let now = nowMs()
    return syncOnQueue {
      state["connected"] = true
      state["state"] = "connected-shadow"
      state["updatedAt"] = now
      state["note"] = "ChatEngine shadow connect (native WebSocket unavailable on this iOS version)"
      appendJournalLocked(event: "connect-shadow", payload: [:])
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
      return snapshot
    }
  }

  func disconnect() -> [String: Any] {
    let clientToClose: ChatRealtimeTransport? = syncOnQueue {
      let now = nowMs()
      autoReconnectEnabled = false
      cancelReconnectLocked()
      reconnectAttempt = 0
      let client = phoenixClient
      phoenixClient = nil
      nativePresenceActive = false
      nativeUserJoinRef = nil
      nativeUserTopic = nil
      nativeChatJoinRefsByRef.removeAll()
      nativeJoinedChatIds.removeAll()
      nativePendingMessagePushRefs.removeAll()
      nativePendingEditPushRefs.removeAll()
      nativePendingDeletePushRefs.removeAll()
      nativePendingCallSignals.removeAll()
      nativePendingCallPushRefs.removeAll()
      nativeUserChannelDemandUntilMs = 0
      outboundReplayWorkItemsByMessageId.values.forEach { $0.cancel() }
      outboundReplayWorkItemsByMessageId.removeAll()
      outboundReplayAttemptsByMessageId.removeAll()
      directMlsRetryWorkItemsByChat.values.forEach { $0.cancel() }
      directMlsRetryWorkItemsByChat.removeAll()
      directMlsReadinessInFlightChatIds.removeAll()
      directMlsKeyRetryAttemptsByChat.removeAll()
      directMlsConfirmationRetryAttemptsByChat.removeAll()
      pendingOutboundDraftsByMessageId.removeAll()
      pendingOutboundQueueByChat.removeAll()
      onlineUsers.removeAll()
      lastSeenByUserId.removeAll()
      surfaceBindings.removeAll()
      openChatChannels.removeAll()
      receiptIndex.removeAll()
      localStatusIndex.removeAll()
      nativeTypingStateByChatId.removeAll()
      peerTypingUserIdsByChatId.removeAll()
      agentProgressByChatId.removeAll()
      agentBridgeHistoryByChat.removeAll()
      agentBridgeHistoryListByChatProvider.removeAll()
      pendingAgentBridgeHistoryRequestsByChat.removeAll()
      nativeRecordingStateByChatId.removeAll()
      pinnedMessagesByChatId.removeAll()
      pinnedFetchInFlightChatIds.removeAll()
      liveMessageRowsByChat.removeAll()
      deletedMessageIdsByChat.removeAll()
      historyRowsByChat.removeAll()
      historyFullyLoadedChats.removeAll()
      historyRowsRestoredFromCacheChats.removeAll()
      historyLoadingChats.removeAll()
      historyOlderExhaustedChats.removeAll()
      historyLoadingOlderChats.removeAll()
      historyHasMoreByChat.removeAll()
      historyNextCursorByChat.removeAll()
      historyNextCursorBoundaryByChat.removeAll()
      cachedSavedMessagesResponse = nil
      chatPeerUserIdsByChatId.removeAll()
      friendPublicKeysByUserId.removeAll()
      pendingFriendKeyChatIdsByUserId.removeAll()
      friendKeyFetchInFlightUserIds.removeAll()
      for (_, item) in friendKeyRetryWorkItemsByUserId {
        item.cancel()
      }
      friendKeyRetryWorkItemsByUserId.removeAll()
      configuredUserId = nil
      cachedDecryptPrivateKey = nil
      cachedDecryptPrivateKeyPem = nil
      cachedDecryptKeyTimestamp = nil
      state["connected"] = false
      state["state"] = "disconnected"
      state["updatedAt"] = now
      state["presenceSource"] = "shadow"
      appendJournalLocked(event: "disconnect", payload: [:])
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
      return client
    }
    if #available(iOS 13.0, *) {
      clientToClose?.disconnect()
    }
    return getStatus()
  }

  func bindSurface(_ payload: [String: Any]) -> [String: Any] {
    let surfaceId =
      normalizedString(payload["surfaceId"]) ?? normalizedString(payload["engineSurfaceId"]) ?? ""
    let chatId = normalizedString(payload["chatId"])
    let myUserId = normalizedUpper(payload["myUserId"])
    let peerUserId = normalizedUpper(payload["peerUserId"])
    let peerAgentId =
      normalizedString(payload["peerAgentId"] ?? payload["peer_agent_id"])
    guard !surfaceId.isEmpty else { return getStatus() }

    let result = syncOnQueue { () -> (snapshot: [String: Any], shouldEnsureTransport: Bool) in
      let nextBinding = SurfaceBinding(
        surfaceId: surfaceId,
        chatId: chatId,
        myUserId: myUserId,
        peerUserId: peerUserId,
        peerAgentId: peerAgentId
      )
      let previousBinding = surfaceBindings[surfaceId]
      guard previousBinding != nextBinding else {
        return (statusSnapshotLocked(), false)
      }

      surfaceBindings[surfaceId] = nextBinding
      let peerBindingChanged =
        previousBinding?.chatId != nextBinding.chatId
        || previousBinding?.peerUserId != nextBinding.peerUserId
        || previousBinding?.peerAgentId != nextBinding.peerAgentId
      if peerBindingChanged, let chatId, !chatId.isEmpty, let peerUserId, !peerUserId.isEmpty {
        chatPeerUserIdsByChatId[chatId] = peerUserId
        if let peerAgentId, !peerAgentId.isEmpty {
          chatPeerAgentIdsByChatId[chatId] = peerAgentId
          agentIdsByPeerUserId[peerUserId] = peerAgentId
        }
        scheduleFriendPublicKeyFetchLocked(
          chatId: chatId,
          peerUserIdHint: peerUserId,
          trigger: "bind_surface"
        )
        scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "surface_peer_bound")
      }
      state["updatedAt"] = nowMs()
      appendJournalLocked(
        event: "bind-surface",
        payload: [
          "surfaceId": surfaceId,
          "chatId": chatId as Any,
          "peerUserId": peerUserId as Any,
          "peerAgentId": peerAgentId as Any,
        ])
      let snapshot = statusSnapshotLocked()
      if peerBindingChanged {
        postChangeLocked(reason: "surfaceBindingChanged", userInfo: ["surfaceId": surfaceId])
      }
      return (snapshot, peerBindingChanged)
    }
    if result.shouldEnsureTransport {
      ensureNativeTransport(trigger: "bind_surface")
    }
    return result.snapshot
  }

  func unbindSurface(_ payload: [String: Any]) -> [String: Any] {
    let surfaceId =
      normalizedString(payload["surfaceId"]) ?? normalizedString(payload["engineSurfaceId"]) ?? ""
    guard !surfaceId.isEmpty else { return getStatus() }
    return syncOnQueue {
      surfaceBindings.removeValue(forKey: surfaceId)
      state["updatedAt"] = nowMs()
      appendJournalLocked(event: "unbind-surface", payload: ["surfaceId": surfaceId])
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "surfaceBindingChanged", userInfo: ["surfaceId": surfaceId])
      return snapshot
    }
  }

  func openChatChannel(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let peerUserIdHint = normalizedUpper(payload["peerUserId"] ?? payload["peer_user_id"])
    if isBuiltInAgentChatId(chatId) {
      return syncOnQueue {
        if let chatId {
          openChatChannels.removeValue(forKey: chatId)
          nativeJoinedChatIds.remove(chatId)
          historyLoadingChats.remove(chatId)
          appendJournalLocked(
            event: "open-chat-channel-skip",
            payload: ["chatId": chatId, "reason": "built_in_agent_surface"]
          )
          VibeDebugLog.log(
            "[ChatEngine][Route] skip normal chat channel for built-in agent chatId=%@",
            chatId
          )
        }
        return statusSnapshotLocked()
      }
    }
    let snapshot = syncOnQueue {
      if let chatId, !chatId.isEmpty {
        if let peerUserIdHint {
          chatPeerUserIdsByChatId[chatId] = peerUserIdHint
          if !isVolatileBridgeAgentChatLocked(chatId: chatId, peerUserId: peerUserIdHint) {
            scheduleFriendPublicKeyFetchLocked(
              chatId: chatId,
              peerUserIdHint: peerUserIdHint,
              trigger: "open_chat_channel"
            )
          }
        }
        let nextCount = (openChatChannels[chatId] ?? 0) + 1
        openChatChannels[chatId] = nextCount
        VibeDebugLog.log(
          "[ChatEngine][Route] openChatChannel chatId=%@ peerUserId=%@ count=%d savedMessages=%@",
          chatId,
          peerUserIdHint ?? "",
          nextCount,
          chatId == "saved_messages" ? "Y" : "N"
        )
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
      }
      appendJournalLocked(event: "open-chat-channel", payload: payload)
      state["updatedAt"] = nowMs()
      let snapshot = statusSnapshotLocked()
      return snapshot
    }
    ensureNativeTransport(trigger: "open_chat_channel")
    return snapshot
  }

  func closeChatChannel(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    return syncOnQueue {
      if let chatId, !chatId.isEmpty, let current = openChatChannels[chatId] {
        if current <= 1 {
          openChatChannels.removeValue(forKey: chatId)
          nativeJoinedChatIds.remove(chatId)
          peerTypingUserIdsByChatId.removeValue(forKey: chatId)
          agentProgressByChatId.removeValue(forKey: chatId)
          if let client = phoenixClient {
            client.leave(topic: chatTopic(for: chatId))
          }
        } else {
          openChatChannels[chatId] = current - 1
        }
      }
      if !hasRealtimeDemandLocked() {
        cancelReconnectLocked()
        reconnectAttempt = 0
      }
      appendJournalLocked(event: "close-chat-channel", payload: payload)
      state["updatedAt"] = nowMs()
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "chatChannelStateChanged", userInfo: ["chatId": chatId as Any])
      return snapshot
    }
  }

  func prefetchChatHistories(chatIds: [String]) {
    queue.async { [weak self] in
      guard let self else { return }
      let startedAt = ProcessInfo.processInfo.systemUptime
      var kicked = 0
      defer {
        NSLog(
          "[Launch] history prefetch kicked=%d of %d in %dms",
          kicked, chatIds.count,
          Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))
      }
      for rawChatId in chatIds {
        guard let chatId = self.normalizedString(rawChatId), !chatId.isEmpty else { continue }
        guard !self.isBuiltInAgentChatId(chatId) else {
          self.appendJournalLocked(
            event: "native-chat-history-skip",
            payload: ["chatId": chatId, "reason": "agent_surface"]
          )
          continue
        }
        kicked += 1
        self.loadChatHistoryIfNeededLocked(chatId: chatId)
      }
    }
  }

  func seedRecentChatHistory(chatId rawChatId: String, messages: [[String: Any]], limit: Int = 5) {
    queue.async { [weak self] in
      guard let self else { return }
      guard let chatId = self.normalizedString(rawChatId), !chatId.isEmpty else { return }
      guard !self.isBuiltInAgentChatId(chatId) else { return }
      _ = self.restoreCachedHistoryRowsLocked(chatId: chatId)
      guard !messages.isEmpty, !self.historyFullyLoadedChats.contains(chatId) else { return }

      let sourceMessages =
        chatId == "saved_messages" ? self.normalizeSavedMessagesLocked(messages) : messages
      let sortedMessages = sourceMessages.sorted { lhs, rhs in
        self.transcriptOrderPrecedes(
          lhsTs: self.transcriptTimestampMs(lhs),
          lhsId: self.rawMessageIdForOrdering(lhs, chatId: chatId),
          rhsTs: self.transcriptTimestampMs(rhs),
          rhsId: self.rawMessageIdForOrdering(rhs, chatId: chatId))
      }
      let recentMessages = Array(sortedMessages.suffix(max(1, min(limit, sortedMessages.count))))
      let rows = self.buildHistoryRowsLocked(chatId: chatId, rawMessages: recentMessages, allowMlsDecryption: false)
      guard !rows.isEmpty else { return }

      let existingCount = self.historyRowsByChat[chatId]?.count ?? 0
      guard existingCount < rows.count else { return }
      self.historyRowsByChat[chatId] = rows
      self.storeMergedChatHistoryIfLoadedLocked(chatId: chatId)
      self.appendJournalLocked(
        event: "native-chat-history-seed-recent",
        payload: ["chatId": chatId, "rows": rows.count]
      )
      self.postChangeLocked(reason: "chatRowsReloaded", userInfo: ["chatId": chatId])
    }
  }

  func seedChatHistories(_ payload: [String: Any]) -> [String: Any] {
    guard let histories = payload["chatHistories"] as? [String: [[String: Any]]] else {
      return ["seeded": 0]
    }

    var triggered = 0
    syncOnQueue {
      for (rawChatId, messagesArray) in histories {
        guard let chatId = normalizedString(rawChatId), !chatId.isEmpty else { continue }
        _ = restoreCachedHistoryRowsLocked(chatId: chatId)
        if !historyFullyLoadedChats.contains(chatId) {
          let sourceMessages =
            chatId == "saved_messages"
            ? normalizeSavedMessagesLocked(messagesArray) : messagesArray
          let rows = buildHistoryRowsLocked(chatId: chatId, rawMessages: sourceMessages, allowMlsDecryption: false)
          guard !rows.isEmpty, rows.count > (historyRowsByChat[chatId]?.count ?? 0) else {
            continue
          }
          historyRowsByChat[chatId] = rows
          historyRowsRestoredFromCacheChats.remove(chatId)
          storeMergedChatHistoryIfLoadedLocked(chatId: chatId)
          triggered += 1
        }
      }
    }

    NSLog(
      "[ChatEngine] seedChatHistories injected %d chats without eager history fetch", triggered)
    return ["seeded": triggered]
  }

  func sendDeliveryReceipt(_ payload: [String: Any]) -> [String: Any] {
    sendReceipt(
      payload,
      status: "delivered",
      eventName: "delivery-receipt",
      wireEvent: "delivery-receipt"
    )
  }

  func sendReadReceipt(_ payload: [String: Any]) -> [String: Any] {
    sendReceipt(
      payload,
      status: "read",
      eventName: "read-receipt",
      wireEvent: "read-receipt"
    )
  }

  func sendCallSignal(_ payload: [String: Any]) -> [String: Any] {
    guard #available(iOS 13.0, *) else {
      return ["accepted": false, "reason": "ios_unavailable"]
    }
    let event = normalizedString(payload["event"]) ?? "call-start"
    guard ["call-start", "call-accepted", "call-end", "webrtc-signal"].contains(event) else {
      return ["accepted": false, "reason": "unsupported_call_event", "event": event]
    }
    guard
      let toUserId = normalizedString(
        payload["toUserId"] ?? payload["to_user_id"] ?? payload["remoteUserId"]
          ?? payload["remote_user_id"])
    else {
      return ["accepted": false, "reason": "missing_to_user_id", "event": event]
    }

    let now = nowMs()
    let callId =
      normalizedString(payload["callId"] ?? payload["call_id"])
      ?? "call_\(now)_\(UUID().uuidString.prefix(8))"
    var wirePayload = makeJSONSafeMap(payload)
    wirePayload["event"] = event
    wirePayload["callId"] = callId
    wirePayload["toUserId"] = toUserId
    let signalId = "\(event):\(callId):\(toUserId):\(now)"
    var shouldConnect = false

    let result = syncOnQueue {
      nativeUserChannelDemandUntilMs = max(nativeUserChannelDemandUntilMs, now + nativeCallSignalDemandMs)
      expirePendingCallSignalsLocked(now: now)

      guard let client = phoenixClient,
        let topic = nativeUserTopic,
        (state["connected"] as? Bool) == true,
        nativePresenceActive
      else {
        nativePendingCallSignals.append(
          PendingCallSignal(id: signalId, event: event, payload: wirePayload, createdAtMs: now))
        appendJournalLocked(
          event: "native-call-signal-queued",
          payload: ["id": signalId, "event": event, "callId": callId, "toUserId": toUserId]
        )
        shouldConnect = true
        state["updatedAt"] = now
        let snapshot = statusSnapshotLocked()
        postChangeLocked(reason: "callSignalQueued", userInfo: ["event": event, "state": snapshot])
        return [
          "accepted": true,
          "transport": "native",
          "event": event,
          "callId": callId,
          "queued": true,
          "reason": "user_channel_not_ready",
        ]
      }

      let ref = client.push(topic: topic, event: event, payload: wirePayload)
      nativePendingCallPushRefs[ref] = signalId
      appendJournalLocked(
        event: "native-call-signal-push",
        payload: [
          "id": signalId,
          "event": event,
          "callId": callId,
          "toUserId": toUserId,
          "ref": ref,
          "topic": topic,
        ])
      state["updatedAt"] = now
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "callSignalSent", userInfo: ["event": event, "state": snapshot])
      return [
        "accepted": true,
        "transport": "native",
        "event": event,
        "callId": callId,
        "queued": false,
        "ref": ref,
      ]
    }

    if shouldConnect {
      DispatchQueue.global(qos: .utility).async { [weak self] in
        self?.ensureNativeTransport(trigger: "call_signal:\(event)")
      }
    }
    return result
  }

  func sendTypingState(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    guard let chatId, !chatId.isEmpty else { return ["accepted": false, "reason": "invalid_chat"] }
    let typing: Bool = {
      switch payload["typing"] {
      case let value as Bool:
        return value
      case let value as NSNumber:
        return value.boolValue
      case let value as String:
        return ["1", "true", "yes", "on"].contains(value.lowercased())
      default:
        return false
      }
    }()
    return syncOnQueue {
      if isBridgeTextModeLocked() {
        return ["accepted": false, "reason": "typing_disabled_in_blackout", "typing": typing]
      }
      let sinceSentMs = Int64(nowMs()) - (nativeTypingSentAtMsByChatId[chatId] ?? 0)
      if nativeTypingStateByChatId[chatId] == typing,
        !typing || sinceSentMs < Self.typingRefreshMs
      {
        return ["accepted": true, "transport": "native", "deduped": true, "typing": typing]
      }
      guard let client = phoenixClient else {
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "typing_no_socket")
        }
        return ["accepted": false, "reason": "no_native_socket", "typing": typing]
      }
      guard nativeJoinedChatIds.contains(chatId), (state["connected"] as? Bool) == true else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "typing_chat_not_joined")
        }
        return ["accepted": false, "reason": "chat_not_joined", "typing": typing]
      }
      nativeTypingStateByChatId[chatId] = typing
      nativeTypingSentAtMsByChatId[chatId] = typing ? Int64(nowMs()) : 0
      let userId = normalizedString(getConfigValueLocked("userId")) ?? "me"
      let event = typing ? "typing" : "stop-typing"
      let ref = client.push(
        topic: chatTopic(for: chatId), event: event, payload: ["userId": userId])
      appendJournalLocked(
        event: "native-\(event)", payload: ["chatId": chatId, "ref": ref, "typing": typing])
      state["updatedAt"] = nowMs()
      postChangeLocked(reason: "typingStateSent", userInfo: ["chatId": chatId, "typing": typing])
      return ["accepted": true, "transport": "native", "ref": ref, "typing": typing]
    }
  }

  func sendRecordingState(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    guard let chatId, !chatId.isEmpty else { return ["accepted": false, "reason": "invalid_chat"] }
    let isRecording: Bool = {
      switch payload["isRecording"] ?? payload["recording"] {
      case let value as Bool:
        return value
      case let value as NSNumber:
        return value.boolValue
      case let value as String:
        return ["1", "true", "yes", "on"].contains(value.lowercased())
      default:
        return false
      }
    }()
    let isLocked: Bool = {
      switch payload["isLocked"] ?? payload["locked"] {
      case let value as Bool:
        return value
      case let value as NSNumber:
        return value.boolValue
      case let value as String:
        return ["1", "true", "yes", "on"].contains(value.lowercased())
      default:
        return false
      }
    }()
    let mode = normalizedString(payload["mode"]) ?? "voice"
    return syncOnQueue {
      if isBridgeTextModeLocked() {
        return [
          "accepted": false,
          "reason": "recording_disabled_in_blackout",
          "isRecording": isRecording,
        ]
      }
      if nativeRecordingStateByChatId[chatId] == isRecording {
        return [
          "accepted": true, "transport": "native", "deduped": true, "isRecording": isRecording,
        ]
      }
      nativeRecordingStateByChatId[chatId] = isRecording
      guard let client = phoenixClient else {
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "recording_no_socket")
        }
        return ["accepted": false, "reason": "no_native_socket", "isRecording": isRecording]
      }
      guard nativeJoinedChatIds.contains(chatId), (state["connected"] as? Bool) == true else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "recording_chat_not_joined")
        }
        return ["accepted": false, "reason": "chat_not_joined", "isRecording": isRecording]
      }
      let userId = normalizedString(getConfigValueLocked("userId")) ?? "me"
      let event = isRecording ? "recording" : "stop-recording"
      var wirePayload: [String: Any] = ["userId": userId]
      if isRecording {
        wirePayload["mode"] = mode
        wirePayload["isLocked"] = isLocked
        if let vad = payload["vad"] { wirePayload["vad"] = vad }
      }
      let ref = client.push(topic: chatTopic(for: chatId), event: event, payload: wirePayload)
      appendJournalLocked(
        event: "native-\(event)",
        payload: [
          "chatId": chatId,
          "ref": ref,
          "isRecording": isRecording,
          "isLocked": isLocked,
          "mode": mode,
        ])
      state["updatedAt"] = nowMs()
      postChangeLocked(
        reason: "recordingStateSent",
        userInfo: [
          "chatId": chatId,
          "isRecording": isRecording,
          "isLocked": isLocked,
          "mode": mode,
        ])
      return ["accepted": true, "transport": "native", "ref": ref, "isRecording": isRecording]
    }
	  }

  func sendAgentBridgeControl(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let provider = normalizedString(payload["provider"] ?? payload["agentBridgeProvider"])
    let action = normalizedString(payload["action"] ?? payload["type"]) ?? "cancel"
    let taskId = normalizedString(payload["taskId"] ?? payload["agentTaskId"] ?? payload["messageId"])
    let teamRunId = normalizedString(payload["teamRunId"] ?? payload["team_run_id"])

    guard let chatId, !chatId.isEmpty else {
      return ["accepted": false, "reason": "invalid_chat"]
    }
    if provider == nil || provider?.isEmpty == true {
      guard let teamRunId, !teamRunId.isEmpty, action == "cancel" || action == "stop" else {
        return ["accepted": false, "reason": "invalid_provider"]
      }
      return syncOnQueue {
        sendAgentBridgeControlLocked(
          chatId: chatId,
          provider: "codex",
          action: action,
          taskId: taskId,
          teamRunId: teamRunId,
          attempt: 0)
      }
    }

    return syncOnQueue {
      sendAgentBridgeControlLocked(
        chatId: chatId,
        provider: provider!,
        action: action,
        taskId: taskId,
        teamRunId: teamRunId,
        attempt: 0)
    }
  }

  func latestTeamWorkerProgressNodes(chatId: String, teamRunId: String) -> [String: [[String: Any]]]?
  {
    guard !chatId.isEmpty, !teamRunId.isEmpty else { return nil }
    return syncOnQueue {
      teamWorkerProgressNodesByChatId[chatId]?[teamRunId]
    }
  }

  private static let bridgeControlMaxAttempts = 8

  private func sendAgentBridgeControlLocked(
    chatId: String,
    provider: String,
    action: String,
    taskId: String?,
    teamRunId: String? = nil,
    attempt: Int
  ) -> [String: Any] {
    let willRetry = attempt + 1 < Self.bridgeControlMaxAttempts
    guard let client = phoenixClient else {
      DispatchQueue.global(qos: .utility).async { [weak self] in
        self?.ensureNativeTransport(trigger: "bridge_control_no_socket")
      }
      scheduleAgentBridgeControlRetryLocked(
        chatId: chatId,
        provider: provider,
        action: action,
        taskId: taskId,
        teamRunId: teamRunId,
        attempt: attempt)
      return ["accepted": false, "reason": "no_native_socket", "willRetry": willRetry]
    }
    guard nativeJoinedChatIds.contains(chatId), (state["connected"] as? Bool) == true else {
      joinNativeChatTopicIfNeededLocked(chatId: chatId)
      DispatchQueue.global(qos: .utility).async { [weak self] in
        self?.ensureNativeTransport(trigger: "bridge_control_chat_not_joined")
      }
      scheduleAgentBridgeControlRetryLocked(
        chatId: chatId,
        provider: provider,
        action: action,
        taskId: taskId,
        teamRunId: teamRunId,
        attempt: attempt)
      return ["accepted": false, "reason": "chat_not_joined", "willRetry": willRetry]
    }

    var wirePayload: [String: Any] = [
      "action": action,
      "provider": provider,
    ]
    if let taskId, !taskId.isEmpty {
      wirePayload["taskId"] = taskId
    }
    if let teamRunId, !teamRunId.isEmpty {
      wirePayload["teamRunId"] = teamRunId
    }
    if let computerId = AgentBridgeSelectionStore.selectedRepository(chatId: chatId)?.computerId,
      !computerId.isEmpty
    {
      wirePayload["computerId"] = computerId
    }
    let ref = client.push(
      topic: chatTopic(for: chatId),
      event: "agent-bridge-control",
      payload: wirePayload
    )
    appendJournalLocked(
      event: "native-agent-bridge-control",
      payload: [
        "chatId": chatId, "provider": provider, "action": action, "ref": ref, "attempt": attempt,
        "teamRunId": teamRunId as Any,
      ]
    )
    state["updatedAt"] = nowMs()
    postChangeLocked(
      reason: "agentBridgeControlSent",
      userInfo: ["chatId": chatId, "provider": provider, "action": action]
    )
    return ["accepted": true, "transport": "native", "ref": ref]
  }

  private func scheduleAgentBridgeControlRetryLocked(
    chatId: String,
    provider: String,
    action: String,
    taskId: String?,
    teamRunId: String? = nil,
    attempt: Int
  ) {
    let nextAttempt = attempt + 1
    guard nextAttempt < Self.bridgeControlMaxAttempts else { return }
    let delay = min(0.75 * Double(nextAttempt), 3.0)
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      _ = self.syncOnQueue {
        self.sendAgentBridgeControlLocked(
          chatId: chatId,
          provider: provider,
          action: action,
          taskId: taskId,
          teamRunId: teamRunId,
          attempt: nextAttempt)
      }
    }
  }

  func requestAgentBridgeHistory(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let provider = normalizedString(payload["provider"] ?? payload["agentBridgeProvider"])
    let mode = normalizedString(payload["mode"]) ?? "list"
    let sessionId = normalizedString(payload["sessionId"] ?? payload["session_id"])
    let requestId = normalizedString(payload["requestId"]) ?? UUID().uuidString
    let before = normalizedString(payload["before"] ?? payload["beforeCursor"] ?? payload["before_cursor"])

    guard let chatId, !chatId.isEmpty else {
      return ["accepted": false, "reason": "invalid_chat"]
    }
    guard let provider, !provider.isEmpty else {
      return ["accepted": false, "reason": "invalid_provider"]
    }

    return syncOnQueue {
      var wirePayload: [String: Any] = [
        "provider": provider,
        "mode": mode,
        "requestId": requestId,
      ]
      if let sessionId, !sessionId.isEmpty {
        wirePayload["sessionId"] = sessionId
      }
      if let before, !before.isEmpty {
        wirePayload["before"] = before
      }
      if let limit = payload["limit"] as? Int, limit > 0 {
        wirePayload["limit"] = limit
      } else if let limit = normalizedString(payload["limit"]), let parsed = Int(limit), parsed > 0 {
        wirePayload["limit"] = parsed
      }
      if let computerId = AgentBridgeSelectionStore.selectedRepository(chatId: chatId)?.computerId,
        !computerId.isEmpty
      {
        wirePayload["computerId"] = computerId
      }

      if AgentBridgeTransport.preference != .cloud,
        sendAgentBridgeHistoryOverLanLocked(
          chatId: chatId, wirePayload: wirePayload, requestId: requestId)
      {
        return ["accepted": true, "transport": "lan", "requestId": requestId]
      }

      return sendAgentBridgeHistoryOverCloudLocked(
        chatId: chatId, wirePayload: wirePayload, requestId: requestId)
    }
  }

  private func sendAgentBridgeHistoryOverLanLocked(
    chatId: String, wirePayload: [String: Any], requestId: String
  ) -> Bool {
    var lanPayload = wirePayload
    lanPayload["chatId"] = chatId
    guard LanBridgeService.shared.send(type: "history_request", payload: lanPayload) else {
      return false
    }

    lanHistoryPendingRequestIds.insert(requestId)
    let cloudFallback = wirePayload
    let mode = normalizedString(wirePayload["mode"]) ?? "list"
    queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
      guard let self else { return }
      guard self.lanHistoryPendingRequestIds.remove(requestId) != nil else { return }
      NSLog(
        "[LanBridge] history %@ over LAN timed out req=%@ — cloud fallback",
        mode, String(requestId.prefix(8)))
      _ = self.sendAgentBridgeHistoryOverCloudLocked(
        chatId: chatId, wirePayload: cloudFallback, requestId: requestId)
    }
    NSLog(
      "[LanBridge] history %@ sent over LAN req=%@ chat=%@",
      mode, String(requestId.prefix(8)), String(chatId.prefix(12)))
    return true
  }

  private func sendAgentBridgeHistoryOverCloudLocked(
    chatId: String, wirePayload: [String: Any], requestId: String
  ) -> [String: Any] {
    guard let client = phoenixClient else {
      queueAgentBridgeHistoryRequestLocked(chatId: chatId, payload: wirePayload)
      DispatchQueue.global(qos: .utility).async { [weak self] in
        self?.ensureNativeTransport(trigger: "bridge_history_no_socket")
      }
      return [
        "accepted": true,
        "transport": "native_queued",
        "reason": "joining_transport",
        "requestId": requestId,
      ]
    }
    guard nativeJoinedChatIds.contains(chatId), (state["connected"] as? Bool) == true else {
      queueAgentBridgeHistoryRequestLocked(chatId: chatId, payload: wirePayload)
      joinNativeChatTopicIfNeededLocked(chatId: chatId)
      DispatchQueue.global(qos: .utility).async { [weak self] in
        self?.ensureNativeTransport(trigger: "bridge_history_chat_not_joined")
      }
      return [
        "accepted": true,
        "transport": "native_queued",
        "reason": "joining_chat",
        "requestId": requestId,
      ]
    }

    let ref = client.push(
      topic: chatTopic(for: chatId),
      event: "agent-bridge-history",
      payload: wirePayload
    )
    appendJournalLocked(
      event: "native-agent-bridge-history-request",
      payload: [
        "chatId": chatId,
        "provider": normalizedString(wirePayload["provider"]) ?? "",
        "mode": normalizedString(wirePayload["mode"]) ?? "list",
        "before": normalizedString(wirePayload["before"]) ?? "",
        "ref": ref,
      ]
    )
    return ["accepted": true, "transport": "native", "ref": ref, "requestId": requestId]
  }

  private func queueAgentBridgeHistoryRequestLocked(chatId: String, payload: [String: Any]) {
    var queued = pendingAgentBridgeHistoryRequestsByChat[chatId] ?? []
    queued.append(payload)
    if queued.count > 12 {
      queued.removeFirst(queued.count - 12)
    }
    pendingAgentBridgeHistoryRequestsByChat[chatId] = queued
    NSLog(
      "[ChatEngine][BridgeHistory] queued chat=%@ mode=%@ request=%@ pending=%d",
      String(chatId.prefix(12)),
      normalizedString(payload["mode"]) ?? "list",
      String((normalizedString(payload["requestId"]) ?? "-").prefix(8)),
      queued.count)
  }

  private func flushPendingAgentBridgeHistoryRequestsLocked(chatId: String) {
    guard
      let client = phoenixClient,
      nativeJoinedChatIds.contains(chatId),
      (state["connected"] as? Bool) == true,
      let queued = pendingAgentBridgeHistoryRequestsByChat.removeValue(forKey: chatId),
      !queued.isEmpty
    else { return }

    for wirePayload in queued {
      let ref = client.push(
        topic: chatTopic(for: chatId),
        event: "agent-bridge-history",
        payload: wirePayload
      )
      appendJournalLocked(
        event: "native-agent-bridge-history-request",
        payload: [
          "chatId": chatId,
          "provider": normalizedString(wirePayload["provider"]) ?? "",
          "mode": normalizedString(wirePayload["mode"]) ?? "list",
          "before": normalizedString(wirePayload["before"]) ?? "",
          "ref": ref,
          "queued": true,
        ]
      )
    }
    NSLog(
      "[ChatEngine][BridgeHistory] flushed chat=%@ requests=%d",
      String(chatId.prefix(12)), queued.count)
  }

  func latestAgentBridgeHistory(chatId rawChatId: String) -> [String: Any]? {
    let chatId = normalizedString(rawChatId) ?? rawChatId
    return syncOnQueue { agentBridgeHistoryByChat[chatId] }
  }

  func latestAgentBridgeHistoryList(chatId rawChatId: String, provider rawProvider: String) -> [String: Any]? {
    let chatId = normalizedString(rawChatId) ?? rawChatId
    let provider = (normalizedString(rawProvider) ?? rawProvider).lowercased()
    let key = "\(chatId)|\(provider)"
    return syncOnQueue { agentBridgeHistoryListByChatProvider[key] }
  }

  func requestAgentBridgeFile(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let provider = normalizedString(payload["provider"] ?? payload["agentBridgeProvider"])
    let filePath = normalizedString(payload["path"] ?? payload["file"])
    let requestId = normalizedString(payload["requestId"]) ?? UUID().uuidString

    guard let chatId, !chatId.isEmpty else { return ["accepted": false, "reason": "invalid_chat"] }
    guard let provider, !provider.isEmpty else { return ["accepted": false, "reason": "invalid_provider"] }
    guard let filePath, !filePath.isEmpty else { return ["accepted": false, "reason": "invalid_path"] }

    return syncOnQueue {
      guard let client = phoenixClient else {
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "bridge_file_no_socket")
        }
        return ["accepted": false, "reason": "no_native_socket"]
      }
      guard nativeJoinedChatIds.contains(chatId), (state["connected"] as? Bool) == true else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "bridge_file_chat_not_joined")
        }
        return ["accepted": false, "reason": "chat_not_joined"]
      }

      var wirePayload: [String: Any] = [
        "provider": provider, "path": filePath, "requestId": requestId,
      ]
      if let computerId = AgentBridgeSelectionStore.selectedRepository(chatId: chatId)?.computerId,
        !computerId.isEmpty
      {
        wirePayload["computerId"] = computerId
      }
      let ref = client.push(
        topic: chatTopic(for: chatId),
        event: "agent-bridge-file",
        payload: wirePayload
      )
      appendJournalLocked(
        event: "native-agent-bridge-file-request",
        payload: ["chatId": chatId, "provider": provider, "path": filePath, "ref": ref]
      )
      return ["accepted": true, "transport": "native", "ref": ref, "requestId": requestId]
    }
  }

  func latestAgentBridgeFile(requestId rawRequestId: String) -> [String: Any]? {
    let requestId = normalizedString(rawRequestId) ?? rawRequestId
    return syncOnQueue { agentBridgeFileByRequestId[requestId] }
  }

  func requestAgentBridgeUsage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let provider = normalizedString(payload["provider"] ?? payload["agentBridgeProvider"])
    let requestId = normalizedString(payload["requestId"]) ?? UUID().uuidString

    guard let chatId, !chatId.isEmpty else { return ["accepted": false, "reason": "invalid_chat"] }
    guard let provider, !provider.isEmpty else { return ["accepted": false, "reason": "invalid_provider"] }

    if Thread.isMainThread {
      queue.async { [weak self] in
        guard let self else { return }
        let result = self.requestAgentBridgeUsageLocked(
          chatId: chatId, provider: provider, requestId: requestId)
        if (result["accepted"] as? Bool) != true {
          self.appendJournalLocked(
            event: "native-agent-bridge-usage-deferred",
            payload: ["chatId": chatId, "provider": provider, "reason": result["reason"] ?? "-"])
        }
      }
      return ["accepted": true, "transport": "native-async", "requestId": requestId]
    }
    return syncOnQueue {
      requestAgentBridgeUsageLocked(chatId: chatId, provider: provider, requestId: requestId)
    }
  }

  private func requestAgentBridgeUsageLocked(chatId: String, provider: String, requestId: String)
    -> [String: Any]
  {
    do {
      guard let client = phoenixClient else {
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "bridge_usage_no_socket")
        }
        return ["accepted": false, "reason": "no_native_socket"]
      }
      guard nativeJoinedChatIds.contains(chatId), (state["connected"] as? Bool) == true else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "bridge_usage_chat_not_joined")
        }
        return ["accepted": false, "reason": "chat_not_joined"]
      }

      var wirePayload: [String: Any] = ["provider": provider, "requestId": requestId]
      if let computerId = AgentBridgeSelectionStore.selectedRepository(chatId: chatId)?.computerId,
        !computerId.isEmpty
      {
        wirePayload["computerId"] = computerId
      }
      let ref = client.push(
        topic: chatTopic(for: chatId),
        event: "agent-bridge-usage",
        payload: wirePayload
      )
      appendJournalLocked(
        event: "native-agent-bridge-usage-request",
        payload: ["chatId": chatId, "provider": provider, "ref": ref]
      )
      return ["accepted": true, "transport": "native", "ref": ref, "requestId": requestId]
    }
  }

  func latestAgentBridgeUsage(requestId rawRequestId: String) -> [String: Any]? {
    let requestId = normalizedString(rawRequestId) ?? rawRequestId
    return syncOnQueue { agentBridgeUsageByRequestId[requestId] }
  }

  func cachedAgentBridgeUsage(chatId rawChatId: String, provider rawProvider: String) -> [String: Any]? {
    let chatId = normalizedString(rawChatId) ?? rawChatId
    let provider = (normalizedString(rawProvider) ?? rawProvider).lowercased()
    guard !chatId.isEmpty, !provider.isEmpty else { return nil }
    let key = "\(chatId)|\(provider)"
    return syncOnQueue { agentBridgeUsageByChatProvider[key] }
  }

  func latestAgentBridgeAsk(requestId rawRequestId: String) -> [String: Any]? {
    let requestId = normalizedString(rawRequestId) ?? rawRequestId
    return syncOnQueue { agentBridgeAskByRequestId[requestId] }
  }

  func activeIsolatedRunId(chatId rawChatId: String?) -> String? {
    guard let chatId = normalizedString(rawChatId), !chatId.isEmpty else { return nil }
    return syncOnQueue { activeIsolatedRunIdByChatId[chatId] }
  }

  func latestAgentPreview(chatId rawChatId: String?) -> AgentPreviewState? {
    latestAgentPreview(chatId: rawChatId, agentUserId: nil)
  }

  /// Several team agents can browse in one chat, so frames are keyed per agent.
  /// A nil agentUserId means "whichever agent painted last".
  func latestAgentPreview(chatId rawChatId: String?, agentUserId rawAgentUserId: String?)
    -> AgentPreviewState?
  {
    guard let chatId = normalizedString(rawChatId), !chatId.isEmpty else { return nil }
    return syncOnQueue {
      if let agentUserId = normalizedString(rawAgentUserId), !agentUserId.isEmpty {
        return latestAgentPreviewByChatId[
          Self.agentComputerKey(chatId: chatId, agentUserId: agentUserId)]
      }
      return latestAgentPreviewByChatId
        .filter { Self.agentComputerKey($0.key, belongsTo: chatId) }
        .map { $0.value }
        .max(by: { $0.updatedAtMs < $1.updatedAtMs })
    }
  }

  static func agentComputerKey(chatId: String, agentUserId: String?) -> String {
    guard let agentUserId, !agentUserId.isEmpty else { return chatId }
    return chatId + "|" + agentUserId
  }

  static func agentComputerKey(_ key: String, belongsTo chatId: String) -> Bool {
    key == chatId || key.hasPrefix(chatId + "|")
  }

  func latestAgentComputer(chatId rawChatId: String?) -> AgentComputerState? {
    latestAgentComputer(chatId: rawChatId, agentUserId: nil)
  }

  /// Nil agentUserId means "whichever agent moved last"; the cell band uses that.
  func latestAgentComputer(chatId rawChatId: String?, agentUserId rawAgentUserId: String?)
    -> AgentComputerState?
  {
    guard let chatId = normalizedString(rawChatId), !chatId.isEmpty else { return nil }
    Self.agentComputerLock.lock()
    defer { Self.agentComputerLock.unlock() }
    if let agentUserId = normalizedString(rawAgentUserId), !agentUserId.isEmpty {
      return Self.agentComputerByChatId[
        Self.agentComputerKey(chatId: chatId, agentUserId: agentUserId)]
    }
    return Self.agentComputerByChatId
      .filter { Self.agentComputerKey($0.key, belongsTo: chatId) }
      .map { $0.value }
      .max(by: { $0.updatedAtMs < $1.updatedAtMs })
  }

  private static func storeAgentComputer(
    _ state: AgentComputerState?, chatId: String, agentUserId: String?
  ) {
    agentComputerLock.lock()
    agentComputerByChatId[agentComputerKey(chatId: chatId, agentUserId: agentUserId)] = state
    agentComputerLock.unlock()
  }

  func agentApprovalMeta(messageId rawMessageId: String?) -> AgentApprovalMeta? {
    guard let messageId = normalizedString(rawMessageId), !messageId.isEmpty else { return nil }
    Self.agentComputerLock.lock()
    defer { Self.agentComputerLock.unlock() }
    return Self.agentApprovalMetaByMessageId[messageId]
  }

  private static func storeAgentApprovalMeta(_ meta: AgentApprovalMeta, messageId: String) {
    agentComputerLock.lock()
    agentApprovalMetaByMessageId[messageId] = meta
    agentComputerLock.unlock()
  }

  func claimAgentBridgeAskPresentation(requestId rawRequestId: String) -> Bool {
    let requestId = normalizedString(rawRequestId) ?? rawRequestId
    guard !requestId.isEmpty else { return false }
    return syncOnQueue {
      if presentedAskRequestIds.contains(requestId) { return false }
      presentedAskRequestIds.insert(requestId)
      return true
    }
  }

  func releaseAgentBridgeAskPresentation(requestId rawRequestId: String) {
    let requestId = normalizedString(rawRequestId) ?? rawRequestId
    guard !requestId.isEmpty else { return }
    syncOnQueue {
      guard agentBridgeAskByRequestId[requestId] != nil else { return }
      presentedAskRequestIds.remove(requestId)
    }
  }

  func outstandingAgentBridgeAskInfo(chatId rawChatId: String, provider rawProvider: String?)
    -> [AnyHashable: Any]?
  {
    let chatId = normalizedString(rawChatId) ?? ""
    guard !chatId.isEmpty else { return nil }
    let provider = (rawProvider ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let published = uiMirror.pendingBridgeAsk(chatId: chatId, provider: provider) {
      return published?.payload
    }
    return syncOnQueue {
      for (rid, payload) in agentBridgeAskByRequestId {
        guard (normalizedString(payload["chatId"]) ?? "") == chatId else { continue }
        if presentedAskRequestIds.contains(rid) { continue }
        let p = (normalizedString(payload["provider"]) ?? "").lowercased()
        if !provider.isEmpty, !p.isEmpty, p != provider { continue }
        return [
          "chatId": chatId,
          "requestId": rid,
          "kind": normalizedString(payload["kind"]) ?? "ask",
          "provider": normalizedString(payload["provider"]) ?? provider,
          "sessionId": normalizedString(payload["sessionId"] ?? payload["session_id"]) ?? "",
          "resumedFromSessionId": normalizedString(
            payload["resumedFromSessionId"] ?? payload["resumed_from_session_id"]) ?? "",
          "reason": "agentBridgeAsk",
        ]
      }
      return nil
    }
  }

  func hasOutstandingAgentBridgeAsk(chatId rawChatId: String, provider rawProvider: String?) -> Bool {
    let chatId = normalizedString(rawChatId) ?? ""
    guard !chatId.isEmpty else { return false }
    let provider = (rawProvider ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return syncOnQueue {
      agentBridgeAskByRequestId.values.contains { payload in
        guard (normalizedString(payload["chatId"]) ?? "") == chatId else { return false }
        let p = (normalizedString(payload["provider"]) ?? "").lowercased()
        return provider.isEmpty || p.isEmpty || p == provider
      }
    }
  }

  @discardableResult
  func sendAgentBridgeAskResponse(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let requestId = normalizedString(payload["requestId"] ?? payload["request_id"])
    let decisionRaw = normalizedString(payload["decision"] ?? payload["action"]) ?? "answer"
    let decision = ["approve", "reject", "answer"].contains(decisionRaw) ? decisionRaw : "answer"
    let provider = normalizedString(payload["provider"] ?? payload["agentBridgeProvider"])

    guard let chatId, !chatId.isEmpty else { return ["accepted": false, "reason": "invalid_chat"] }
    guard let requestId, !requestId.isEmpty else {
      return ["accepted": false, "reason": "invalid_request_id"]
    }

    let storedAsk: [String: Any]? = syncOnQueue {
      let ask = agentBridgeAskByRequestId.removeValue(forKey: requestId)
      agentTurnRunningAtMsByChatId[chatId] = Int64(nowMs())
      return ask
    }
    let isIsolated = normalizedString(storedAsk?["runtime"]) == "isolated"
    let storedRunId = normalizedString(storedAsk?["runId"] ?? storedAsk?["run_id"])

    var wirePayload: [String: Any] = ["requestId": requestId, "decision": decision]
    if let provider, !provider.isEmpty { wirePayload["provider"] = provider }
    if let computerId = AgentBridgeSelectionStore.selectedRepository(chatId: chatId)?.computerId,
      !computerId.isEmpty
    {
      wirePayload["computerId"] = computerId
    }
    if isIsolated, let storedRunId, !storedRunId.isEmpty {
      wirePayload["runId"] = storedRunId
    }
    if let answer = payload["answer"] as? [String: Any], !answer.isEmpty {
      if isIsolated {
        wirePayload["answer"] = answer
      } else if let sealed = AgentRuntimeCrypto.encrypt(["answer": answer]) {
        wirePayload["answerEnc"] = sealed
      }
    }

    return syncOnQueue {
      guard let client = phoenixClient else {
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "bridge_ask_no_socket")
        }
        return ["accepted": false, "reason": "no_native_socket"]
      }
      guard nativeJoinedChatIds.contains(chatId), (state["connected"] as? Bool) == true else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "bridge_ask_chat_not_joined")
        }
        return ["accepted": false, "reason": "chat_not_joined"]
      }

      let ref = client.push(
        topic: chatTopic(for: chatId),
        event: "agent-bridge-ask-response",
        payload: wirePayload
      )
      appendJournalLocked(
        event: "native-agent-bridge-ask-response",
        payload: ["chatId": chatId, "requestId": requestId, "decision": decision, "ref": ref]
      )
      return ["accepted": true, "transport": "native", "ref": ref, "requestId": requestId]
    }
  }

  @discardableResult
  func cancelAgentRun(chatId rawChatId: String, runId rawRunId: String) -> [String: Any] {
    let chatId = normalizedString(rawChatId) ?? rawChatId
    let runId = normalizedString(rawRunId) ?? rawRunId
    guard !chatId.isEmpty, !runId.isEmpty else {
      return ["accepted": false, "reason": "invalid_args"]
    }
    return syncOnQueue {
      guard let client = phoenixClient else {
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "agent_run_cancel_no_socket")
        }
        return ["accepted": false, "reason": "no_native_socket"]
      }
      guard nativeJoinedChatIds.contains(chatId), (state["connected"] as? Bool) == true else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        DispatchQueue.global(qos: .utility).async { [weak self] in
          self?.ensureNativeTransport(trigger: "agent_run_cancel_chat_not_joined")
        }
        return ["accepted": false, "reason": "chat_not_joined"]
      }
      let ref = client.push(
        topic: chatTopic(for: chatId),
        event: "agent-run-control",
        payload: ["chatId": chatId, "runId": runId, "action": "cancel"]
      )
      appendJournalLocked(
        event: "native-agent-run-cancel",
        payload: ["chatId": chatId, "runId": runId, "ref": ref]
      )
      return ["accepted": true, "transport": "native", "ref": ref, "runId": runId]
    }
  }

  @discardableResult
  func loadAgentBridgeSessionIntoChat(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"]) ?? ""
    let provider = normalizedString(payload["provider"]) ?? ""
    let sessionId = normalizedString(payload["sessionId"] ?? payload["session_id"]) ?? ""
    let topicHint = normalizedString(payload["topic"]) ?? ""
    guard !chatId.isEmpty, !provider.isEmpty, !sessionId.isEmpty else {
      return ["accepted": false, "reason": "invalid_session"]
    }

    let requestId = UUID().uuidString
    queue.async { [weak self] in
      self?.loadAgentBridgeSessionIntoChatLocked(
        chatId: chatId,
        provider: provider,
        sessionId: sessionId,
        topicHint: topicHint,
        requestId: requestId
      )
    }
    return [
      "accepted": true,
      "transport": "engine_queued",
      "requestId": requestId,
    ]
  }

  private func loadAgentBridgeSessionIntoChatLocked(
    chatId: String,
    provider: String,
    sessionId: String,
    topicHint: String,
    requestId: String
  ) {
    dispatchPrecondition(condition: .onQueue(queue))

    seedBridgeSessionTopicLocked(chatId: chatId, topic: topicHint)

    if let live = liveBridgeSessionIngestByChatId[chatId],
      live.sessionId == sessionId,
      lastIngestedBridgeSessionSigByChatId[chatId] != nil
    {
      NSLog(
        "[ChatEngine][BridgeMount] loadSession SKIP same session chat=%@ session=%@",
        String(chatId.suffix(12)), String(sessionId.prefix(12))
      )
      postChangeLocked(reason: "chatRowsReloaded", userInfo: ["chatId": chatId])
      return
    }
    let now = Int64(nowMs())
    if let inflight = sessionLoadInflightByChatId[chatId],
      inflight.sessionId == sessionId,
      now - inflight.atMs < 5000
    {
      NSLog(
        "[ChatEngine][BridgeMount] loadSession SKIP inflight chat=%@ session=%@",
        String(chatId.suffix(12)), String(sessionId.prefix(12))
      )
      return
    }
    sessionLoadInflightByChatId[chatId] = (
      sessionId: sessionId,
      requestId: requestId,
      atMs: Int64(nowMs())
    )

    let result = requestAgentBridgeHistory([
      "chatId": chatId,
      "provider": provider,
      "mode": "detail",
      "sessionId": sessionId,
      "requestId": requestId,
      "limit": Self.bridgeSessionPageLimit,
    ])
    if (result["accepted"] as? Bool) == true {
      pendingBridgeSessionIngestByRequestId[requestId] = (chatId: chatId, provider: provider)
      liveBridgeSessionIngestByChatId[chatId] = (
        provider: provider,
        sessionId: sessionId,
        requestId: requestId
      )
      lastIngestedBridgeSessionSigByChatId.removeValue(forKey: chatId)
      bridgeSessionPagingByChatId[chatId] = (
        provider: provider, sessionId: sessionId, nextBefore: nil, hasMoreBefore: true,
        loadingOlder: false
      )
    } else {
      if sessionLoadInflightByChatId[chatId]?.requestId == requestId {
        sessionLoadInflightByChatId.removeValue(forKey: chatId)
      }
    }
  }

  private func seedBridgeSessionTopicLocked(chatId: String, topic: String) {
    dispatchPrecondition(condition: .onQueue(queue))
    let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if bridgeSessionTopicByChatId[chatId] != trimmed {
      bridgeSessionTopicByChatId[chatId] = trimmed
      postChangeLocked(reason: "agentBridgeSessionTopic", userInfo: ["chatId": chatId])
    }
  }

  func cancelAutomaticAgentBridgeSessionLoad(chatId rawChatId: String) {
    guard let chatId = normalizedString(rawChatId), !chatId.isEmpty else { return }
    syncOnQueue {
      guard let inflight = currentSessionLoadInflightByChatId.removeValue(forKey: chatId) else {
        return
      }
      pendingBridgeSessionIngestByRequestId.removeValue(forKey: inflight.requestId)
      NSLog(
        "[ChatEngine][BridgeMount] cancel automatic current-session load chat=%@ requestId=%@ after fresh send",
        String(chatId.suffix(12)), String(inflight.requestId.prefix(8))
      )
    }
  }

  @discardableResult
  func loadOlderAgentBridgeSessionChunk(chatId rawChatId: String) -> [String: Any] {
    let chatId = normalizedString(rawChatId) ?? rawChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else { return ["accepted": false, "reason": "invalid_chat"] }

    let spec: (provider: String, sessionId: String, before: String)? = syncOnQueue {
      guard var paging = bridgeSessionPagingByChatId[chatId],
        paging.hasMoreBefore,
        !paging.loadingOlder,
        let before = paging.nextBefore,
        !before.isEmpty
      else {
        return nil
      }
      paging.loadingOlder = true
      bridgeSessionPagingByChatId[chatId] = paging
      return (provider: paging.provider, sessionId: paging.sessionId, before: before)
    }
    guard let spec else { return ["accepted": false, "reason": "no_older_page"] }

    let requestId = UUID().uuidString
    let result = requestAgentBridgeHistory([
      "chatId": chatId,
      "provider": spec.provider,
      "mode": "detail",
      "sessionId": spec.sessionId,
      "before": spec.before,
      "requestId": requestId,
      "limit": Self.bridgeSessionPageLimit,
    ])
    if (result["accepted"] as? Bool) == true {
      syncOnQueue {
        pendingBridgeSessionIngestByRequestId[requestId] = (chatId: chatId, provider: spec.provider)
      }
    } else {
      syncOnQueue {
        if var paging = bridgeSessionPagingByChatId[chatId], paging.sessionId == spec.sessionId {
          paging.loadingOlder = false
          bridgeSessionPagingByChatId[chatId] = paging
        }
      }
    }
    return result
  }

  func clearLiveBridgeSessionIngest(chatId rawChatId: String) {
    guard let chatId = normalizedString(rawChatId), !chatId.isEmpty else { return }
    queue.async { [weak self] in
      guard let self else { return }
      self.liveBridgeSessionIngestByChatId.removeValue(forKey: chatId)
      self.bridgeSettledSessionSigByChatId.removeValue(forKey: chatId)
      self.bridgeSessionPagingByChatId.removeValue(forKey: chatId)
      self.pendingBridgeSessionIngestByRequestId = self.pendingBridgeSessionIngestByRequestId.filter {
        $0.value.chatId != chatId
      }
      if self.bridgeSessionTopicByChatId.removeValue(forKey: chatId) != nil {
        self.postChangeLocked(reason: "agentBridgeSessionTopic", userInfo: ["chatId": chatId])
      }
    }
  }

  func agentBridgeSessionTopic(chatId rawChatId: String) -> String? {
    guard let chatId = normalizedString(rawChatId), !chatId.isEmpty else { return nil }
    return syncOnQueue { bridgeSessionTopicByChatId[chatId] }
  }

  private let publishedBridgeSessionLock = NSLock()
  private var publishedBridgeSessionIds: [String: String] = [:]
  private var publishedBridgeSessionsReady = false

  func liveBridgeSessionId(chatId rawChatId: String) -> String? {
    guard let chatId = normalizedString(rawChatId), !chatId.isEmpty else { return nil }
    if Thread.isMainThread {
      publishedBridgeSessionLock.lock()
      let ready = publishedBridgeSessionsReady
      let published = publishedBridgeSessionIds[chatId]
      publishedBridgeSessionLock.unlock()
      if ready {
        queue.async { [weak self] in self?.publishBridgeSessionIds() }
        return published
      }
    }
    return syncOnQueue {
      publishBridgeSessionIds()
      return liveBridgeSessionIngestByChatId[chatId]?.sessionId
    }
  }

  private func publishBridgeSessionIds() {
    var snapshot: [String: String] = [:]
    snapshot.reserveCapacity(liveBridgeSessionIngestByChatId.count)
    for (chatId, ingest) in liveBridgeSessionIngestByChatId {
      snapshot[chatId] = ingest.sessionId
    }
    publishedBridgeSessionLock.lock()
    publishedBridgeSessionIds = snapshot
    publishedBridgeSessionsReady = true
    publishedBridgeSessionLock.unlock()
  }

  private func rearmLiveBridgeSessionLocked(chatId: String, trigger: String) {
    guard let live = liveBridgeSessionIngestByChatId[chatId] else { return }
    let now = Int64(nowMs())
    let lastArm = lastBridgeRearmAtMsByChatId[chatId] ?? 0
    let softTriggers: Set<String> = [
      "current_session_load", "chat_joined", "open", "poll", "already_live",
    ]
    let soft = softTriggers.contains(trigger) || trigger.hasPrefix("poll#")
    if soft, trigger != "force_recover" {
      if lastIngestedBridgeSessionSigByChatId[chatId] != nil, !live.sessionId.isEmpty {
        NSLog(
          "[ChatEngine][BridgeMount] rearm SKIP soft chat=%@ trigger=%@ session=%@ (already ingested)",
          String(chatId.suffix(12)), trigger, String(live.sessionId.prefix(12))
        )
        return
      }
    }
    if now - lastArm < 1200, trigger != "force_recover" {
      NSLog(
        "[ChatEngine][BridgeMount] rearm SKIPPED chat=%@ trigger=%@ ageMs=%lld (coalesce)",
        String(chatId.suffix(12)), trigger, now - lastArm
      )
      return
    }
    let requestId = UUID().uuidString
    var wirePayload: [String: Any] = [
      "provider": live.provider,
      "mode": "detail",
      "requestId": requestId,
      "limit": Self.bridgeSessionPageLimit,
    ]
    if !live.sessionId.isEmpty { wirePayload["sessionId"] = live.sessionId }

    let result: [String: Any]
    if AgentBridgeTransport.preference != .cloud,
      sendAgentBridgeHistoryOverLanLocked(
        chatId: chatId, wirePayload: wirePayload, requestId: requestId)
    {
      result = ["accepted": true, "transport": "lan", "requestId": requestId]
    } else {
      guard phoenixClient != nil, nativeJoinedChatIds.contains(chatId),
        (state["connected"] as? Bool) == true
      else { return }
      result = sendAgentBridgeHistoryOverCloudLocked(
        chatId: chatId, wirePayload: wirePayload, requestId: requestId)
    }
    guard (result["accepted"] as? Bool) == true else { return }

    lastBridgeRearmAtMsByChatId[chatId] = now
    liveBridgeSessionIngestByChatId[chatId] = (
      provider: live.provider, sessionId: live.sessionId, requestId: requestId
    )
    if trigger == "force_recover" {
      lastIngestedBridgeSessionSigByChatId.removeValue(forKey: chatId)
    }
    pendingBridgeSessionIngestByRequestId[requestId] = (chatId: chatId, provider: live.provider)
    let transport = normalizedString(result["transport"]) ?? "native"
    let ref = normalizedString(result["ref"]) ?? ""
    NSLog(
      "[ChatEngine][BridgeMount] rearm chat=%@ provider=%@ session=%@ trigger=%@ transport=%@ phoenix=%@",
      String(chatId.suffix(12)),
      live.provider,
      String(live.sessionId.prefix(12)),
      trigger,
      transport,
      (state["connected"] as? Bool) == true ? "ws-up" : "ws-down"
    )
    appendJournalLocked(
      event: "rearm-live-bridge-session",
      payload: [
        "chatId": chatId, "provider": live.provider, "trigger": trigger, "ref": ref,
      ]
    )
  }

  static func strippedBridgeInstructionPreamble(_ text: String) -> String {
    guard text.hasPrefix("Vibe bridge startup prepared these instruction files"),
      let marker = text.range(of: "User task:")
    else { return text }
    return String(text[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func bridgeMirrorComparableText(_ text: String) -> String {
    var body = strippedBridgeInstructionPreamble(text)
    if body.hasPrefix("The user attached "), let marker = body.range(of: "\n\n") {
      body = String(body[marker.upperBound...])
    }
    return body.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static let bridgeMirrorDedupWindowMs: Int64 = 48 * 3600 * 1000

  private static let transcriptISO8601MsFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private static let transcriptISO8601Formatter = ISO8601DateFormatter()

  static func parseTranscriptTimestampMs(_ raw: Any?) -> Int64? {
    func fromNumber(_ value: Double) -> Int64? {
      guard value > 0 else { return nil }
      return value < 100_000_000_000 ? Int64(value * 1000.0) : Int64(value)
    }
    if let value = raw as? Int64 { return fromNumber(Double(value)) }
    if let value = raw as? Int { return fromNumber(Double(value)) }
    if let value = raw as? Double { return fromNumber(value) }
    guard
      let string = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !string.isEmpty
    else { return nil }
    if let numeric = Double(string) { return fromNumber(numeric) }
    if let date = transcriptISO8601MsFormatter.date(from: string) {
      return Int64(date.timeIntervalSince1970 * 1000.0)
    }
    if let date = transcriptISO8601Formatter.date(from: string) {
      return Int64(date.timeIntervalSince1970 * 1000.0)
    }
    return nil
  }

  private func bridgeSessionSignatureText(_ raw: Any?) -> String {
    let text = normalizedString(raw) ?? ""
    guard !text.isEmpty else { return "0" }
    let head = String(text.prefix(32))
    let tail = String(text.suffix(32))
    return "\(text.count):\(head):\(tail)"
  }

  private func bridgeSessionProgressNodesSignature(_ raw: Any?) -> String {
    guard let nodes = raw as? [[String: Any]], !nodes.isEmpty else { return "0" }
    return nodes.enumerated().map { index, node in
      let id = normalizedString(node["id"]) ?? "\(index)"
      let kind = normalizedString(node["kind"] ?? node["itemType"]) ?? ""
      let status = normalizedString(node["status"]) ?? ""
      let label = bridgeSessionSignatureText(
        node["label"] ?? node["title"] ?? node["text"] ?? node["content"] ?? node["message"]
          ?? node["summary"])
      let target = bridgeSessionSignatureText(
        node["target"] ?? node["path"] ?? node["file_path"] ?? node["filePath"])
      let tokens = parseLongValue(node["tokens"]).map(String.init) ?? ""
      let duration = parseLongValue(node["durationMs"] ?? node["duration_ms"]).map(String.init) ?? ""
      let added = parseLongValue(node["added"]).map(String.init) ?? ""
      let removed = parseLongValue(node["removed"]).map(String.init) ?? ""
      return "\(id)|\(kind)|\(status)|\(label)|\(target)|\(tokens)|\(duration)|\(added)|\(removed)"
    }.joined(separator: "||")
  }

  private func ingestAgentBridgeSessionLocked(
    chatId: String,
    provider: String,
    payload: [String: Any]
  ) {
    guard let session = payload["session"] as? [String: Any] else { return }
    let sessionId =
      normalizedString(session["id"]) ?? normalizedString(payload["sessionId"]) ?? UUID().uuidString
    let hasMoreBefore =
      (session["hasMoreBefore"] as? Bool)
      ?? (session["has_more_before"] as? Bool)
      ?? false
    let nextBefore =
      normalizedString(session["nextBefore"] ?? session["next_before"] ?? session["before"])
    let responseBefore =
      normalizedString(payload["before"] ?? payload["beforeCursor"] ?? payload["before_cursor"])
    if var paging = bridgeSessionPagingByChatId[chatId], paging.sessionId == sessionId {
      if responseBefore != nil || paging.nextBefore == nil || paging.loadingOlder {
        paging.nextBefore = nextBefore
        paging.hasMoreBefore = hasMoreBefore
      }
      paging.loadingOlder = false
      bridgeSessionPagingByChatId[chatId] = paging
    } else {
      bridgeSessionPagingByChatId[chatId] = (
        provider: provider, sessionId: sessionId, nextBefore: nextBefore,
        hasMoreBefore: hasMoreBefore, loadingOlder: false
      )
    }
    if let topic = normalizedString(session["topic"]), !topic.isEmpty,
      bridgeSessionTopicByChatId[chatId] != topic
    {
      bridgeSessionTopicByChatId[chatId] = topic
      postChangeLocked(reason: "agentBridgeSessionTopic", userInfo: ["chatId": chatId])
    }
    let rawMessages = session["messages"] as? [[String: Any]] ?? []
    guard !rawMessages.isEmpty else { return }

    let lastRaw = rawMessages.last
    let lastRawUid = normalizedString(lastRaw?["uid"] ?? lastRaw?["id"]) ?? ""
    let lastRawTextSig = bridgeSessionSignatureText(lastRaw?["text"])
    let lastRawNodeSig = bridgeSessionProgressNodesSignature(
      lastRaw?["progressNodes"] ?? lastRaw?["progress_nodes"])
    let lastRawRunning = (lastRaw?["running"] as? Bool) == true
    let ingestSig =
      "\(rawMessages.count):\(sessionId):\(lastRawUid):\(lastRawTextSig):\(lastRawNodeSig):\(lastRawRunning)"
    if lastIngestedBridgeSessionSigByChatId[chatId] == ingestSig {
      if lastRawRunning {
        agentTurnRunningAtMsByChatId[chatId] = Int64(nowMs())
        bridgeClearSessionSettledLocked(chatId: chatId, sessionId: sessionId)
        let nodes =
          (lastRaw?["progressNodes"] as? [[String: Any]])
          ?? (lastRaw?["progress_nodes"] as? [[String: Any]]) ?? []
        setAgentProgressLocked(
          chatId: chatId,
          label: agentProgressLabelFromNodes(nodes) ?? "Thinking",
          tool: nil,
          status: "running")
      } else {
        agentTurnRunningAtMsByChatId.removeValue(forKey: chatId)
        clearAgentProgressLocked(chatId: chatId, reason: "ingestSigMatch(settled)")
        let tailContentSig = "\(lastRawUid):\(lastRawTextSig):\(lastRawNodeSig)"
        bridgeMarkSessionSettledLocked(chatId: chatId, sessionId: sessionId, contentSig: tailContentSig)
        settleBridgeTailRowStreamingLocked(chatId: chatId, sessionId: sessionId, uid: lastRawUid)
      }
      return
    }
    let previousIngestSig = lastIngestedBridgeSessionSigByChatId[chatId]
    let lastRawRole = (normalizedString(lastRaw?["role"]) ?? "").lowercased()
    if let previousIngestSig, previousIngestSig.contains(":\(sessionId):"),
      previousIngestSig != ingestSig, lastRawRole != "user",
      !bridgeSessionIsSettledLocked(chatId: chatId, sessionId: sessionId)
    {
      agentTurnRunningAtMsByChatId[chatId] = Int64(nowMs())
    }
    lastIngestedBridgeSessionSigByChatId[chatId] = ingestSig

    let agentName: String = {
      switch provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "claude": return "Claude"
      case "codex": return "Codex"
      case "grok": return "Grok"
      case "agy", "antigravity": return "Agy"
      default: return provider.capitalized
      }
    }()
    let baseTs = Int64(nowMs())
    let me = currentUserIdLocked()
    var lastMessageId: String?
    var ingestedIds = Set<String>()
    var deltaInsertedIds: [String] = []
    var deltaUpdatedIds: [String] = []
    var deltaDeletedIds: [String] = []
    var ownUserMirrorTwins: [(text: String, ts: Int64)] = []
    func collectOwnMirrorTwin(_ mid: String, _ row: [String: Any]) {
      guard !mid.hasPrefix("bridge-"), !mid.hasPrefix("stream-"),
        messageIsMe(fromRow: row),
        let message = row["message"] as? [String: Any],
        let rawText = normalizedString(message["text"])
      else { return }
      let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      ownUserMirrorTwins.append((text, messageTimestampMs(fromRow: row)))
    }
    for (mid, row) in liveMessageRowsByChat[chatId] ?? [:] {
      collectOwnMirrorTwin(mid, row)
    }
    for row in historyRowsByChat[chatId] ?? [] {
      if let mid = messageId(fromRow: row) { collectOwnMirrorTwin(mid, row) }
    }
    let hasLiveStreamRow =
      (liveMessageRowsByChat[chatId] ?? [:]).keys.contains { $0.hasPrefix("stream-") }
    var sawRunningAgentItem = false
    var ingestedAgentRow = false
    var runningTurnProgressNodes: [[String: Any]] = []
    let tailAgentIndex = rawMessages.lastIndex {
      (normalizedString($0["role"]) ?? "").lowercased() != "user"
    }
    var tailAgentContentSig = ""

    for (index, item) in rawMessages.enumerated() {
      let role = (normalizedString(item["role"]) ?? "").lowercased()
      let text = (normalizedString(item["text"]) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let hasProgressNodes = (item["progressNodes"] as? [[String: Any]])?.isEmpty == false
      guard !text.isEmpty || hasProgressNodes else { continue }
      if role == "user" {
        let mirrorText = Self.bridgeMirrorComparableText(text)
        let mirrorTs =
          Self.parseTranscriptTimestampMs(item["ts"] ?? item["timestamp"]) ?? baseTs
        if !mirrorText.isEmpty,
          ownUserMirrorTwins.contains(where: {
            $0.text == mirrorText && abs($0.ts - mirrorTs) <= Self.bridgeMirrorDedupWindowMs
          })
        {
          continue
        }
      }
      let isRunningTranscriptItem = role != "user" && (item["running"] as? Bool) == true
      if isRunningTranscriptItem {
        sawRunningAgentItem = true
        runningTurnProgressNodes =
          (item["progressNodes"] as? [[String: Any]])
          ?? (item["progress_nodes"] as? [[String: Any]]) ?? []
        if hasLiveStreamRow { continue }
      }
      let agentBodyText = text
      let progressNodesPayload: Any? = item["progressNodes"] ?? item["progress_nodes"]
      let stableKey =
        normalizedString(item["uid"]) ?? normalizedString(item["id"]) ?? "\(index)"
      let messageId = "bridge-\(sessionId)-\(stableKey)"
      let timestampMs =
        Self.parseTranscriptTimestampMs(item["ts"] ?? item["timestamp"]) ?? (baseTs + Int64(index))

      var synthetic: [String: Any] = [
        "id": messageId,
        "type": "text",
        "timestamp": timestampMs,
      ]
      if role == "user" {
        if let me, !me.isEmpty { synthetic["fromId"] = me }
        synthetic["encryptedContent"] = Self.strippedBridgeInstructionPreamble(text)
      } else {
        let providerAgentUserId =
          Self.bridgeAgentUserId(forProvider: provider) ?? Self.agentUserId
        synthetic["isAgentMessage"] = true
        synthetic["plainContent"] = agentBodyText
        synthetic["agentName"] = agentName
        synthetic["agentUsername"] = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        synthetic["fromId"] = providerAgentUserId
        synthetic["agentUserId"] = providerAgentUserId
        var meta: [String: Any] = [
          "agentWorkerVia": "bridge",
          "bridgeSessionId": sessionId,
          "agentName": agentName,
          "agentUserId": providerAgentUserId,
          "agentUsername": provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        ]
        let isTailAgentItem = (index == tailAgentIndex)
        if isTailAgentItem {
          let itemUid = normalizedString(item["uid"] ?? item["id"]) ?? "\(index)"
          let itemTextSig = bridgeSessionSignatureText(item["text"])
          let itemNodeSig = bridgeSessionProgressNodesSignature(
            item["progressNodes"] ?? item["progress_nodes"])
          tailAgentContentSig = "\(itemUid):\(itemTextSig):\(itemNodeSig)"
          if isRunningTranscriptItem,
            let latched = bridgeSettledSessionSigByChatId[chatId]?[sessionId],
            latched != tailAgentContentSig
          {
            bridgeClearSessionSettledLocked(chatId: chatId, sessionId: sessionId)
          }
        }
        let streamingFlag =
          isRunningTranscriptItem
          || (isTailAgentItem && bridgeRunIsLiveLocked(chatId: chatId, sessionId: sessionId))
        meta["isStreaming"] = streamingFlag
        synthetic["isStreaming"] = streamingFlag
        if let enc = normalizedString(item["agentRuntimeEnc"] ?? item["agent_runtime_enc"]) {
          meta["agentRuntimeEnc"] = enc
        }
        if let canRevert = item["canRevert"] ?? item["can_revert"] {
          meta["canRevert"] = canRevert
        }
        if let aKind = normalizedString(item["kind"]) {
          meta["agentMsgKind"] = aKind
        }
        if let aEnc = normalizedString(item["agentActionEnc"] ?? item["agent_action_enc"]) {
          meta["agentActionEnc"] = aEnc
        }
        if let nodes = progressNodesPayload {
          if isRunningTranscriptItem, var mutableNodes = nodes as? [[String: Any]] {
            mutableNodes = Self.collapseLiveTextProgressNodes(mutableNodes)
            for index in mutableNodes.indices.reversed() {
              let kind = (normalizedString(mutableNodes[index]["kind"]) ?? "").lowercased()
              if kind == "text" { continue }
              let rawStatus = normalizedString(mutableNodes[index]["status"])?.lowercased() ?? ""
              if ["failed", "error", "cancelled", "canceled", "stopped"].contains(rawStatus) {
                continue
              }
              mutableNodes[index]["status"] = "running"
              break
            }
            meta["progressNodes"] = mutableNodes
          } else {
            meta["progressNodes"] = nodes
          }
        }
        if let actionsEnc = normalizedString(item["agentActionsEnc"] ?? item["agent_actions_enc"]) {
          meta["agentActionsEnc"] = actionsEnc
        }
        synthetic["metadata"] = meta
      }
      let wasPresent =
        liveMessageRowsByChat[chatId]?[messageId] != nil
        || (historyRowsByChat[chatId] ?? []).contains {
          self.messageId(fromRow: $0) == messageId
        }
      _ = applyNativeIncomingMessageEventLocked(
        chatId: chatId, payload: synthetic, postDelta: false)
      if wasPresent {
        deltaUpdatedIds.append(messageId)
      } else {
        deltaInsertedIds.append(messageId)
      }
      ingestedIds.insert(messageId)
      if role != "user" { ingestedAgentRow = true }
      lastMessageId = messageId
    }

    if ingestedAgentRow, !sawRunningAgentItem {
      let sinceRunningMs = Int64(nowMs()) - (agentTurnRunningAtMsByChatId[chatId] ?? 0)
      let hasOutstandingAskLocked = agentBridgeAskByRequestId.values.contains { payload in
        (normalizedString(payload["chatId"]) ?? "") == chatId
      }
      if hasOutstandingAskLocked {
        VibeDebugLog.log(
          "[EmptyTrace] ingestSettle HOLD chatId=%@ reason=outstandingAsk sinceRunningMs=%lld",
          String(chatId.suffix(12)), sinceRunningMs)
        agentTurnRunningAtMsByChatId[chatId] = Int64(nowMs())
      } else if sinceRunningMs >= Self.agentTurnRunningGraceMs {
        let removal = removeAgentStreamRowsLocked(
          chatId: chatId, agentUserId: Self.bridgeAgentUserId(forProvider: provider))
        deltaDeletedIds.append(contentsOf: removal.removedIds)
        agentTurnRunningAtMsByChatId.removeValue(forKey: chatId)
        clearAgentProgressLocked(chatId: chatId, reason: "ingestSettle(noRunningTurn)")
        bridgeMarkSessionSettledLocked(
          chatId: chatId, sessionId: sessionId, contentSig: tailAgentContentSig)
      }
    }

    if sawRunningAgentItem {
      agentTurnRunningAtMsByChatId[chatId] = Int64(nowMs())
      let requestId = normalizedString(payload["requestId"]) ?? UUID().uuidString
      let existing = liveBridgeSessionIngestByChatId[chatId]
      if existing?.sessionId != sessionId || existing?.requestId != requestId {
        liveBridgeSessionIngestByChatId[chatId] = (
          provider: provider, sessionId: sessionId, requestId: requestId
        )
      }
      setAgentProgressLocked(
        chatId: chatId,
        label: agentProgressLabelFromNodes(runningTurnProgressNodes) ?? "Thinking",
        tool: nil,
        status: "running"
      )
    }

    let windowTruncated = (session["truncated"] as? Bool) ?? false
    if !windowTruncated {
      let sessionPrefix = "bridge-\(sessionId)-"
      var cachedSessionIds = Set<String>()
      for key in (liveMessageRowsByChat[chatId] ?? [:]).keys where key.hasPrefix(sessionPrefix) {
        cachedSessionIds.insert(key)
      }
      for row in historyRowsByChat[chatId] ?? [] {
        if let mid = messageId(fromRow: row), mid.hasPrefix(sessionPrefix) {
          cachedSessionIds.insert(mid)
        }
      }
      let alreadyDeleted = deletedMessageIdsByChat[chatId] ?? []
      var staleIds = cachedSessionIds.subtracting(ingestedIds).subtracting(alreadyDeleted)
      if !staleIds.isEmpty {
        VibeDebugLog.log(
          "[EmptyTrace] tombstone chatId=%@ stale=%d cached=%d ingested=%d truncated=N",
          String(chatId.suffix(12)), staleIds.count, cachedSessionIds.count, ingestedIds.count)
        let sinceRunningMs = Int64(nowMs()) - (agentTurnRunningAtMsByChatId[chatId] ?? 0)
        let askOutstanding = agentBridgeAskByRequestId.values.contains { payload in
          (normalizedString(payload["chatId"]) ?? "") == chatId
        }
        let runIsLive = askOutstanding || sinceRunningMs < Self.agentTurnRunningGraceMs
        if runIsLive, staleIds.count > 2 {
          VibeDebugLog.log(
            "[EmptyTrace] tombstone SKIP chatId=%@ stale=%d (live run — refusing mass removal)",
            String(chatId.suffix(12)), staleIds.count)
          staleIds.removeAll()
        }
      }
      if !staleIds.isEmpty {
        var perChat = liveMessageRowsByChat[chatId] ?? [:]
        var deleted = deletedMessageIdsByChat[chatId] ?? Set<String>()
        for staleId in staleIds {
          perChat.removeValue(forKey: staleId)
          deleted.insert(staleId)
        }
        if perChat.isEmpty {
          liveMessageRowsByChat.removeValue(forKey: chatId)
        } else {
          liveMessageRowsByChat[chatId] = perChat
        }
        deletedMessageIdsByChat[chatId] = deleted
        storeMergedChatHistoryIfLoadedLocked(chatId: chatId)
        deltaDeletedIds.append(contentsOf: staleIds.sorted())
      }
    }

    if let lastMessageId {
      postChangeLocked(
        reason: "chatMessageInserted",
        userInfo: ["chatId": chatId, "messageId": lastMessageId, "state": statusSnapshotLocked()]
      )
    }
    postChatDeltaLocked(
      chatId: chatId,
      inserted: Array(Set(deltaInsertedIds)).sorted(),
      updated: Array(Set(deltaUpdatedIds)).sorted(),
      deleted: Array(Set(deltaDeletedIds)).sorted(),
      source: "bridge")
  }

  func retryOutgoingMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let messageId = normalizedString(payload["messageId"] ?? payload["message_id"])
    return syncOnQueue {
      guard let messageId else {
        return ["accepted": false, "reason": "invalid_message"]
      }
      canceledOutboundMessageIds.remove(messageId)
      let draft: [String: Any]
      if let existing = pendingOutboundDraftsByMessageId[messageId] {
        draft = existing
      } else if let rebuilt = rebuildOutboundDraftFromStoredRowLocked(
        chatId: chatId, messageId: messageId)
      {
        NSLog(
          "[ChatEngine] retry REBUILT draft chatId=%@ messageId=%@ — in-memory draft was gone",
          String((chatId ?? "-").prefix(12)), String(messageId.prefix(12)))
        pendingOutboundDraftsByMessageId[messageId] = rebuilt
        draft = rebuilt
      } else {
        NSLog(
          "[ChatEngine] retry REFUSED chatId=%@ messageId=%@ — no draft and no re-sendable row",
          String((chatId ?? "-").prefix(12)), String(messageId.prefix(12)))
        return ["accepted": false, "reason": "missing_draft", "messageId": messageId]
      }
      let resolvedChatId = chatId ?? normalizedString(draft["chatId"] ?? draft["chat_id"]) ?? ""
      guard !resolvedChatId.isEmpty else {
        return ["accepted": false, "reason": "invalid_chat", "messageId": messageId]
      }
      cancelDirectMlsReadinessLocked(chatId: resolvedChatId, resetAttempts: true)
      VibeSecureSessions.shared.clearPeerKeysUnavailable(chatId: resolvedChatId)
      upsertLocalStatusLocked(
        chatId: resolvedChatId,
        messageId: messageId,
        status: "pending",
        allowDowngrade: true
      )
      queueOutboundDraftLocked(
        chatId: resolvedChatId, messageId: messageId, payload: draft, reason: "manual_retry")
      scheduleReplayQueuedOutboundLocked(chatId: resolvedChatId, trigger: "manual_retry")
      DispatchQueue.global(qos: .utility).async { [weak self] in
        self?.ensureNativeTransport(trigger: "manual_retry")
      }
      postChangeLocked(
        reason: "messageStatusChanged",
        userInfo: ["chatId": resolvedChatId, "messageId": messageId, "status": "pending"]
      )
      return ["accepted": true, "queued": true, "messageId": messageId, "state": "pending"]
    }
  }

  func cachePeerPublicKey(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let peerUserId = normalizedUpper(payload["peerUserId"] ?? payload["peer_user_id"] ?? payload["userId"] ?? payload["id"])
    let publicKey = extractPublicKeyValue(from: payload)
    return syncOnQueue {
      guard let chatId, !chatId.isEmpty, let peerUserId, !peerUserId.isEmpty else {
        return ["accepted": false, "reason": "invalid_peer"]
      }
      chatPeerUserIdsByChatId[chatId] = peerUserId
      if let publicKey, !publicKey.isEmpty {
        friendPublicKeysByUserId[peerUserId] = publicKey
        pendingFriendKeyChatIdsByUserId.removeValue(forKey: peerUserId)
        friendKeyRetryWorkItemsByUserId[peerUserId]?.cancel()
        friendKeyRetryWorkItemsByUserId.removeValue(forKey: peerUserId)
        scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "peer_public_key_cached")
      } else {
        scheduleFriendPublicKeyFetchLocked(
          chatId: chatId,
          peerUserIdHint: peerUserId,
          trigger: "cache_peer_missing_key"
        )
      }
      appendJournalLocked(
        event: "peer-public-key-cache",
        payload: [
          "chatId": chatId,
          "peerUserId": peerUserId,
          "hasPublicKey": publicKey != nil,
        ]
      )
      return ["accepted": true, "chatId": chatId, "peerUserId": peerUserId, "hasPublicKey": publicKey != nil]
    }
  }

  func cancelOutgoingMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let messageId = normalizedString(payload["messageId"] ?? payload["message_id"])
    return syncOnQueue {
      guard let messageId else {
        return ["accepted": false, "reason": "invalid_message"]
      }
      let resolvedChatId =
        chatId
        ?? pendingOutboundDraftsByMessageId[messageId].flatMap {
          normalizedString($0["chatId"] ?? $0["chat_id"])
        }
        ?? ""
      guard !resolvedChatId.isEmpty else {
        return ["accepted": false, "reason": "invalid_chat", "messageId": messageId]
      }
      let activeUploadTask = activeMediaUploadTasksByMessageId.removeValue(forKey: messageId)
      let hadActiveUpload = activeUploadTask != nil
      activeUploadTask?.cancel()
      canceledOutboundMessageIds.insert(messageId)
      removeQueuedOutboundDraftLocked(chatId: resolvedChatId, messageId: messageId, dropDraft: true)
      setLiveMessageUploadProgressLocked(chatId: resolvedChatId, messageId: messageId, progress: nil)
      removeMessageIndicesLocked(chatId: resolvedChatId, messageId: messageId)
      markLiveMessageDeletedLocked(chatId: resolvedChatId, messageId: messageId)
      appendJournalLocked(
        event: "native-outgoing-cancel",
        payload: [
          "chatId": resolvedChatId,
          "messageId": messageId,
          "hadActiveUpload": hadActiveUpload,
        ])
      let snapshot = statusSnapshotLocked()
      postChangeLocked(
        reason: "outgoingMessageCanceled",
        userInfo: [
          "chatId": resolvedChatId,
          "messageId": messageId,
          "state": snapshot,
        ])
      postChangeLocked(
        reason: "chatMessageDeleted",
        userInfo: [
          "chatId": resolvedChatId,
          "messageId": messageId,
          "action": "deleted",
          "state": snapshot,
        ])
      postChatDeltaLocked(
        chatId: resolvedChatId, inserted: [], updated: [], deleted: [messageId], source: "delete")
      return ["accepted": true, "messageId": messageId, "state": "removed"]
    }
  }

  func sendMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let providedMessageId =
      normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
    let type = (normalizedString(payload["type"]) ?? "text").lowercased()
    let text = normalizedString(payload["text"]) ?? ""
    let metadata = payload["metadata"] as? [String: Any] ?? [:]
    guard let chatId, !chatId.isEmpty else {
      return ["accepted": false, "reason": "invalid_chat"]
    }
    let supportedTypes: Set<String> = [
      "text", "image", "gif", "file", "voice", "video", "music", "location", "contact",
      "sticker",
    ]
    guard supportedTypes.contains(type) else {
      return ["accepted": false, "reason": "unsupported_type", "type": type]
    }
    let transportMode = syncOnQueue { transportModeLocked() }
    if transportMode == "bridge_text" && type != "text" {
      return ["accepted": false, "reason": "media_disabled_in_blackout", "type": type]
    }
    let metadataValue: (String, [String]) -> Any? = { key, aliases in
      if let value = payload[key] { return value }
      for alias in aliases {
        if let value = payload[alias] { return value }
      }
      if let value = metadata[key] { return value }
      for alias in aliases {
        if let value = metadata[alias] { return value }
      }
      return nil
    }

    let mediaUrl = normalizedString(
      metadataValue("mediaUrl", ["media_url", "previewUrl", "preview_url"]))
    let localPlaybackMediaUrl = mediaUrl.flatMap { self.isLocalMediaURI($0) ? $0 : nil }
    let fileName = normalizedString(metadataValue("fileName", ["file_name"]))
    let fileSize = parseLongValue(metadataValue("fileSize", ["file_size"]))
    let latitude = parseDoubleValue(metadataValue("latitude", []))
    let longitude = parseDoubleValue(metadataValue("longitude", []))
    let duration = parseDoubleValue(metadataValue("duration", []))
    let width = parseLongValue(metadataValue("width", []))
    let height = parseLongValue(metadataValue("height", []))
    let caption = normalizedString(metadataValue("caption", []))
    let thumbnailBase64 = normalizedString(metadataValue("thumbnailBase64", ["thumbnail_base64"]))
    var mediaKey = normalizedString(metadataValue("mediaKey", ["media_key"]))
    let contact = metadataValue("contact", [])
    let viewOnce = metadataValue("viewOnce", ["view_once"])
    let mediaTtlSeconds = metadataValue("mediaTtlSeconds", ["media_ttl_seconds"])
    let isVideoNote = metadataValue("isVideoNote", ["is_video_note"])
    let waveform = metadataValue("waveform", [])
    let stickerId = normalizedString(metadataValue("stickerId", []))
    let stickerPackId = normalizedString(metadataValue("stickerPackId", ["packId", "pack_id"]))
    let stickerBundleFileName = normalizedString(
      metadataValue("stickerBundleFileName", ["bundleFileName", "bundle_file_name"]))
    let stickerEmoji = normalizedString(metadataValue("emoji", []))
    let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if type == "text" && !hasText {
      return ["accepted": false, "reason": "empty_text"]
    }
    if ["image", "gif", "file", "voice", "video", "music"].contains(type) {
      guard let mediaUrl, !mediaUrl.isEmpty else {
        return ["accepted": false, "reason": "missing_media_url", "type": type]
      }
    }
    if type == "location" && (latitude == nil || longitude == nil) {
      return ["accepted": false, "reason": "invalid_location"]
    }
    if type == "contact" && contact == nil {
      return ["accepted": false, "reason": "missing_contact"]
    }

    let messageId = providedMessageId ?? UUID().uuidString.lowercased()
    let timestampMs =
      parseLongValue(payload["timestampMs"] ?? payload["timestamp"] ?? payload["timestamp_ms"])
      ?? Int64(nowMs())
    let replyToId =
      normalizedString(payload["replyToId"] ?? payload["reply_to_id"])
      ?? normalizedString(metadata["replyToId"] ?? metadata["reply_to_id"])
    let peerUserIdHint = normalizedUpper(payload["peerUserId"] ?? payload["peer_user_id"])
    let explicitPeerAgentId =
      normalizedString(
        payload["peerAgentId"] ?? payload["peer_agent_id"] ?? payload["mentionedAgentId"]
          ?? payload["mentioned_agent_id"])

    return syncOnQueue {
      canceledOutboundMessageIds.remove(messageId)
      var effectivePayload = payload
      effectivePayload["messageId"] = messageId
      let isGroup =
        (payload["isGroup"] as? Bool) == true || (payload["isGroupOrChannel"] as? Bool) == true
      let isChannel = (payload["isChannel"] as? Bool) == true
      NSLog(
        "[ChatEngine] sendMessage START chatId=%@ messageId=%@ isGroup=%@", chatId, messageId,
        isGroup ? "true" : "false")

      if let peerUserIdHint {
        chatPeerUserIdsByChatId[chatId] = peerUserIdHint
      }
      if let explicitPeerAgentId, !explicitPeerAgentId.isEmpty {
        chatPeerAgentIdsByChatId[chatId] = explicitPeerAgentId
        if let peerUserIdHint {
          agentIdsByPeerUserId[peerUserIdHint] = explicitPeerAgentId
        }
      }
      let peerUserId = peerUserIdHint ?? chatPeerUserIdsByChatId[chatId]
      let peerAgentId = explicitPeerAgentId ?? resolvePeerAgentIdLocked(
        chatId: chatId, peerUserIdHint: peerUserId)
      NSLog(
        "[AgentRoute] sendMessage routing chatId=%@ messageId=%@ explicitPeerAgentId=%@ resolvedPeerAgentId=%@ peerUserId=%@ willRoute=%@",
        chatId, messageId, explicitPeerAgentId ?? "nil", peerAgentId ?? "nil",
        peerUserId ?? "nil",
        (peerAgentId?.isEmpty == false) ? "agent-cleartext" : "e2e-peer")
      let bridgeProvider = bridgeProviderForChatLocked(
        chatId: chatId,
        peerUserId: peerUserId,
        peerAgentId: peerAgentId,
        metadata: metadata
      )
      let isVolatileBridgeSend = bridgeProvider != nil
      var deferredBridgeSendReason: String? = nil
      if isVolatileBridgeSend {
        clearVolatileBridgeHistoryLocked(chatId: chatId, reason: "bridge_send_start")
        if phoenixClient == nil || (state["connected"] as? Bool) != true {
          deferredBridgeSendReason = "no_native_socket"
          scheduleReconnectLocked(reason: "bridge_send_no_socket")
          DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.ensureNativeTransport(trigger: "bridge_send_no_socket")
          }
        } else if !nativeJoinedChatIds.contains(chatId) {
          deferredBridgeSendReason = "chat_not_joined"
          joinNativeChatTopicIfNeededLocked(chatId: chatId)
          DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.ensureNativeTransport(trigger: "bridge_send_chat_not_joined")
          }
        }
      }

      let optimisticStartMs = nowMs()
      var decryptedFields: [String: Any] = ["text": text]
      if !metadata.isEmpty { decryptedFields["metadata"] = makeJSONSafeMap(metadata) }
      if let mediaUrl { decryptedFields["mediaUrl"] = mediaUrl }
      if let localPlaybackMediaUrl { decryptedFields["localMediaUrl"] = localPlaybackMediaUrl }
      if let fileName { decryptedFields["fileName"] = fileName }
      if let fileSize { decryptedFields["fileSize"] = fileSize }
      if let latitude { decryptedFields["latitude"] = latitude }
      if let longitude { decryptedFields["longitude"] = longitude }
      if let duration { decryptedFields["duration"] = duration }
      if let width { decryptedFields["width"] = width }
      if let height { decryptedFields["height"] = height }
      if let replyToId { decryptedFields["replyToId"] = replyToId }
      if let contact { decryptedFields["contact"] = contact }
      if let caption { decryptedFields["caption"] = caption }
      if let thumbnailBase64 { decryptedFields["thumbnailBase64"] = thumbnailBase64 }
      if let mediaKey { decryptedFields["mediaKey"] = mediaKey }
      if let viewOnce { decryptedFields["viewOnce"] = viewOnce }
      if let mediaTtlSeconds { decryptedFields["mediaTtlSeconds"] = mediaTtlSeconds }
      if let isVideoNote { decryptedFields["isVideoNote"] = isVideoNote }
      if let waveform { decryptedFields["waveform"] = waveform }
      if let stickerId { decryptedFields["stickerId"] = stickerId }
      if let stickerPackId { decryptedFields["stickerPackId"] = stickerPackId }
      if let stickerBundleFileName {
        decryptedFields["stickerBundleFileName"] = stickerBundleFileName
      }
      if let stickerEmoji { decryptedFields["emoji"] = stickerEmoji }
      var optimisticRow = buildLiveRowPayloadLocked(
        chatId: chatId,
        messageId: messageId,
        fromId: normalizedString(getConfigValueLocked("userId")),
        type: type,
        timestampMs: timestampMs,
        encryptedContent: nil,
        decryptedFields: decryptedFields,
        forceIsMe: true
      )
      if var message = optimisticRow["message"] as? [String: Any] {
        message["status"] = "sending"
        if let replyToId { message["replyToId"] = replyToId }
        optimisticRow["message"] = message
      }
      let isNewOptimisticRow = upsertLiveMessageRowLocked(
        chatId: chatId, messageId: messageId, row: optimisticRow)
      upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "sending")
      postChangeLocked(
        reason: isNewOptimisticRow ? "chatMessageInserted" : "chatMessageChanged",
        userInfo: [
          "chatId": chatId, "messageId": messageId,
          "action": isNewOptimisticRow ? "inserted" : "updated",
        ])
      postChangeLocked(
        reason: "messageStatusChanged",
        userInfo: ["chatId": chatId, "messageId": messageId, "status": "sending"])
      postChatDeltaLocked(
        chatId: chatId,
        inserted: isNewOptimisticRow ? [messageId] : [],
        updated: isNewOptimisticRow ? [] : [messageId],
        deleted: [], source: "optimistic")
      NSLog(
        "[ChatEngine] sendMessage optimistic row emitted in %dms chatId=%@ messageId=%@",
        Int(nowMs() - optimisticStartMs), chatId, messageId)

      if let deferReason = deferredBridgeSendReason {
        upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "pending")
        queueOutboundDraftLocked(
          chatId: chatId, messageId: messageId, payload: effectivePayload, reason: deferReason)
        NSLog(
          "[ChatEngine] sendMessage bridge deferred (warm-up) chatId=%@ messageId=%@ reason=%@",
          chatId, messageId, deferReason)
        postChangeLocked(
          reason: "messageStatusChanged",
          userInfo: ["chatId": chatId, "messageId": messageId, "status": "pending"])
        return [
          "accepted": true, "queued": true, "reason": deferReason,
          "messageId": messageId,
          "state": "pending",
          "bridgeProvider": bridgeProvider ?? "",
        ]
      }

      let isSavedMessagesChat = chatId == "saved_messages"
      let isHumanDirectMessage =
        !isGroup && !isChannel && !isSavedMessagesChat && !isVolatileBridgeSend
        && (peerAgentId ?? "").isEmpty
      if isHumanDirectMessage {
        effectivePayload["__requiresConfirmedMls"] = true
        if let mlsPeerUserId = normalizedUpper(peerUserId) {
          effectivePayload["peerUserId"] = mlsPeerUserId
        }
      }
      let apiBase = self.apiBaseURLLocked()
      let token = self.authHeaderTokenLocked()
      let userId = normalizedString(self.getConfigValueLocked("userId"))

      if isHumanDirectMessage,
        !VibeSecureSessions.shared.isPeerConfirmed(chatId: chatId)
      {
        let mlsPeerUserId = normalizedUpper(effectivePayload["peerUserId"] ?? peerUserId)
        let waitReason: String
        if mlsPeerUserId == nil {
          waitReason = "waiting_for_peer_identity"
        } else if VibeSecureSessions.shared.hasSession(chatId: chatId) {
          waitReason = "waiting_for_peer_confirmation"
        } else if VibeSecureSessions.shared.peerKeysUnavailable(chatId: chatId) {
          waitReason = "waiting_for_peer_keys"
        } else {
          waitReason = "mls_establishing"
        }
        upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "pending")
        queueOutboundDraftLocked(
          chatId: chatId, messageId: messageId, payload: effectivePayload, reason: waitReason)
        appendJournalLocked(
          event: "native-send-message-queued",
          payload: ["chatId": chatId, "messageId": messageId, "reason": waitReason])
        postChangeLocked(
          reason: "messageStatusChanged",
          userInfo: ["chatId": chatId, "messageId": messageId, "status": "pending"])
        if let mlsPeerUserId {
          ensureDirectMlsReadinessLocked(chatId: chatId, peerUserId: mlsPeerUserId)
        }
        return [
          "accepted": true, "queued": true, "reason": waitReason,
          "messageId": messageId,
          "state": "pending",
        ]
      }

      if VibeSecureSessions.isGroupSendEnabled,
        isGroup,
        !isChannel,
        !VibeSecureSessions.shared.isIneligible(chatId: chatId),
        !VibeSecureSessions.shared.peerKeysUnavailable(chatId: chatId),
        let mlsApiBase = apiBase,
        !VibeSecureSessions.shared.hasSession(chatId: chatId)
      {
        upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "pending")
        queueOutboundDraftLocked(
          chatId: chatId, messageId: messageId, payload: effectivePayload,
          reason: "mls_establishing")
        let onSettled: (Bool) -> Void = { [weak self] retry in
          guard let self, retry else { return }
          self.queue.async {
            self.scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "mls_established")
          }
        }
        if let myUserId = userId {
          VibeSecureEstablishment.establishGroup(
            chatId: chatId, myUserId: myUserId, apiBase: mlsApiBase, token: token,
            completion: onSettled)
        }
        return [
          "accepted": true, "queued": true, "reason": "mls_establishing",
          "messageId": messageId,
          "state": "pending",
        ]
      }

      let needsUpload =
        ["image", "gif", "file", "voice", "video", "music"].contains(type)
        && (mediaUrl != nil)
        && isLocalMediaURI(mediaUrl!)

      var uploadTargetUrl: String? = nil
      if needsUpload {
        uploadTargetUrl = mediaUrl
        if fileSize == nil, let localUri = mediaUrl, let localURL = localFileURL(from: localUri) {
          let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
          if let size = attrs?[.size] as? Int64, size > 0 {
            let fileSizeChanged = mutateLiveMessagePayloadLocked(
              chatId: chatId, messageId: messageId
            ) { message in
              message["fileSize"] = size
              var meta = (message["metadata"] as? [String: Any]) ?? [:]
              meta["fileSize"] = size
              message["metadata"] = meta
            }
            if fileSizeChanged {
              postChatDeltaLocked(
                chatId: chatId, inserted: [], updated: [messageId], deleted: [],
                source: "optimistic")
            }
          }
        }
        setLiveMessageUploadProgressLocked(chatId: chatId, messageId: messageId, progress: 0.0)
        postChangeLocked(
          reason: "chatMessageChanged",
          userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
        )
      }

      DispatchQueue.global(qos: .userInitiated).async {
        [weak self, uploadTargetUrl] in
        guard let self = self else { return }

        var finalMediaUrl = mediaUrl
        var finalFileName = fileName
        var finalFileSize = fileSize
        var finalMediaKey = mediaKey
        var finalWidth = width
        var finalHeight = height
        var finalThumbnailBase64 = thumbnailBase64
        var localEffectivePayload = effectivePayload
        var localOptimisticRow = optimisticRow

        if ["image", "gif", "video", "file"].contains(type),
          (finalWidth == nil || finalHeight == nil)
        {
          let localForDims = uploadTargetUrl ?? localPlaybackMediaUrl ?? mediaUrl
          if let localForDims,
            let size = chatMediaFillPixelSize(fromLocalURI: localForDims),
            size.width > 1.0, size.height > 1.0
          {
            finalWidth = Int64(size.width)
            finalHeight = Int64(size.height)
            chatMediaRecordNaturalSize(size, for: localForDims)
            if var message = localOptimisticRow["message"] as? [String: Any] {
              message["width"] = finalWidth as Any
              message["height"] = finalHeight as Any
              var meta = (message["metadata"] as? [String: Any]) ?? [:]
              meta["width"] = finalWidth as Any
              meta["height"] = finalHeight as Any
              message["metadata"] = meta
              localOptimisticRow["message"] = message
            }
          }
        }

        if let localMediaUrl = uploadTargetUrl {
          guard let apiBase = apiBase, let token = token, let userId = userId else {
            self.queue.async {
              self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "pending")
              self.queueOutboundDraftLocked(
                chatId: chatId, messageId: messageId, payload: localEffectivePayload,
                reason: "missing_upload_config")
              self.appendJournalLocked(
                event: "native-media-upload-error",
                payload: [
                  "chatId": chatId,
                  "messageId": messageId,
                  "reason": "missing_upload_config",
                ])
              self.setLiveMessageUploadProgressLocked(
                chatId: chatId, messageId: messageId, progress: nil)
              self.postChangeLocked(
                reason: "chatMessageChanged",
                userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
              )
              self.postChangeLocked(
                reason: "messageStatusChanged",
                userInfo: ["chatId": chatId, "messageId": messageId, "status": "pending"])
            }
            return
          }

          self.queue.async {
            self.appendJournalLocked(
              event: "native-media-upload-start",
              payload: [
                "chatId": chatId,
                "messageId": messageId,
                "type": type,
              ])
            self.setLiveMessageUploadProgressLocked(
              chatId: chatId, messageId: messageId, progress: 0.0)
            self.postChangeLocked(
              reason: "chatMessageChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
            )
          }

          let uploadOutcome = self.uploadLocalMediaLocked(
            localUri: localMediaUrl,
            messageType: type,
            fileNameHint: fileName,
            userId: userId,
            token: token,
            apiBase: apiBase,
            messageId: messageId
          ) { progress in
            self.queue.async { [weak self] in
              guard let self else { return }
              if self.canceledOutboundMessageIds.contains(messageId) { return }
              let scaledProgress = max(0.0, min(1.0, Double(progress)))
              if self.setLiveMessageUploadProgressLocked(
                chatId: chatId,
                messageId: messageId,
                progress: scaledProgress
              ) {
                self.postChangeLocked(
                  reason: "mediaUploadProgress",
                  userInfo: [
                    "chatId": chatId,
                    "messageId": messageId,
                    "progress": scaledProgress,
                  ]
                )
              }
            }
          }

          if let uploadResult = uploadOutcome.result {
            finalMediaUrl = uploadResult.remoteUrl
            if finalFileName == nil { finalFileName = uploadResult.fileName }
            if finalFileSize == nil { finalFileSize = uploadResult.fileSize }
            finalMediaKey = uploadResult.mediaKey

            if ["image", "gif", "video"].contains(type) {
              chatMediaSeedRemoteCacheFromLocalFile(
                localURI: localMediaUrl,
                remoteURL: uploadResult.remoteUrl,
                mediaKey: finalMediaKey
              )
            }

            if ["image", "gif", "video", "file"].contains(type),
              finalWidth == nil || finalHeight == nil || finalThumbnailBase64 == nil
            {
              if finalWidth == nil || finalHeight == nil,
                let size = chatMediaFillPixelSize(fromLocalURI: localMediaUrl),
                size.width > 1.0, size.height > 1.0
              {
                finalWidth = Int64(size.width)
                finalHeight = Int64(size.height)
                chatMediaRecordNaturalSize(size, for: localMediaUrl)
                chatMediaRecordNaturalSize(size, for: uploadResult.remoteUrl)
              }
              let localPath: String? = {
                if let url = URL(string: localMediaUrl), url.isFileURL { return url.path }
                return localMediaUrl.hasPrefix("/") ? localMediaUrl : nil
              }()
              if let localPath {
                let headerSize = chatMediaImageHeaderSize(atPath: localPath)
                let decodesAsImage =
                  headerSize.map { $0.width > 1.0 && $0.height > 1.0 } ?? false
                if finalThumbnailBase64 == nil, decodesAsImage || type != "file",
                  let image = UIImage(contentsOfFile: localPath)
                {
                  finalThumbnailBase64 = chatMicroThumbnailJPEGBase64(from: image)
                }
              }
              NSLog(
                "[MediaDims] type=%@ dims=%@ thumb=%@ local=%@",
                type, (finalWidth != nil && finalHeight != nil) ? "Y" : "MISSING",
                finalThumbnailBase64 != nil ? "Y" : "MISSING", localPath ?? "<not-a-file>")
            }

            if ["voice", "audio", "music"].contains(type) {
              let localForSeed = localPlaybackMediaUrl ?? localMediaUrl
              let remoteForSeed = uploadResult.remoteUrl
              let seedFileName = finalFileName ?? fileName
              DispatchQueue.main.async {
                VoiceBubblePlaybackCoordinator.shared.seedRemoteVoiceCacheFromLocal(
                  localMediaURL: localForSeed,
                  remoteMediaURL: remoteForSeed,
                  fileName: seedFileName
                )
              }
            }

            var nextMetadata = (localEffectivePayload["metadata"] as? [String: Any]) ?? [:]
            nextMetadata["mediaUrl"] = uploadResult.remoteUrl

            let extraLocalUrls =
              (nextMetadata["extraLocalMediaUrls"] as? [String])?
              .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
            nextMetadata.removeValue(forKey: "extraLocalMediaUrls")
            if !extraLocalUrls.isEmpty {
              var urls: [String] = [uploadResult.remoteUrl]
              var keys: [String] = [finalMediaKey ?? ""]
              for extraUri in extraLocalUrls {
                let outcome = self.uploadLocalMediaLocked(
                  localUri: extraUri,
                  messageType: type,
                  fileNameHint: nil,
                  userId: userId,
                  token: token,
                  apiBase: apiBase,
                  messageId: messageId
                )
                guard let extraResult = outcome.result else {
                  NSLog(
                    "[MultiImage] extra upload FAILED msgId=%@ reason=%@",
                    messageId, outcome.reason ?? "-")
                  continue
                }
                urls.append(extraResult.remoteUrl)
                keys.append(extraResult.mediaKey ?? "")
                chatMediaSeedRemoteCacheFromLocalFile(
                  localURI: extraUri,
                  remoteURL: extraResult.remoteUrl,
                  mediaKey: extraResult.mediaKey
                )
              }
              if urls.count > 1 {
                nextMetadata["attachmentUrls"] = urls
                nextMetadata["attachmentMediaKeys"] = keys
              }
              NSLog(
                "[MultiImage] msgId=%@ uploaded=%d of %d", messageId, urls.count,
                extraLocalUrls.count + 1)
            }

            if let localPlaybackMediaUrl { nextMetadata["localMediaUrl"] = localPlaybackMediaUrl }
            if let finalFileName { nextMetadata["fileName"] = finalFileName }
            if let finalFileSize { nextMetadata["fileSize"] = finalFileSize }
            if let finalMediaKey { nextMetadata["mediaKey"] = finalMediaKey }
            if let finalWidth { nextMetadata["width"] = finalWidth }
            if let finalHeight { nextMetadata["height"] = finalHeight }

            localEffectivePayload["metadata"] = nextMetadata
            localEffectivePayload["chatId"] = chatId
            localEffectivePayload["messageId"] = messageId
            localEffectivePayload["type"] = type
            localEffectivePayload["text"] = text
            localEffectivePayload["mediaUrl"] = uploadResult.remoteUrl

            if var message = localOptimisticRow["message"] as? [String: Any] {
              message["mediaUrl"] = uploadResult.remoteUrl
              if let localPlaybackMediaUrl { message["localMediaUrl"] = localPlaybackMediaUrl }
              if let finalFileName { message["fileName"] = finalFileName }
              if let finalFileSize { message["fileSize"] = finalFileSize }
              if let finalMediaKey { message["mediaKey"] = finalMediaKey }
              if let finalWidth { message["width"] = finalWidth }
              if let finalHeight { message["height"] = finalHeight }
              var metadata = (message["metadata"] as? [String: Any]) ?? [:]
              metadata["mediaUrl"] = uploadResult.remoteUrl
              if let finalMediaKey { metadata["mediaKey"] = finalMediaKey }
              if let localPlaybackMediaUrl { metadata["localMediaUrl"] = localPlaybackMediaUrl }
              if let finalWidth { metadata["width"] = finalWidth }
              if let finalHeight { metadata["height"] = finalHeight }
              message["metadata"] = metadata
              localOptimisticRow["message"] = message
            }

            let threadMediaUrl = finalMediaUrl
            let threadOptimisticRow = localOptimisticRow
            self.queue.async {
              self.upsertLiveMessageRowLocked(
                chatId: chatId, messageId: messageId, row: threadOptimisticRow)
              NSLog(
                "[ChatEngine] voice upload complete chatId=%@ messageId=%@ remoteUrl=%@ localPlayback=%@ type=%@",
                chatId,
                messageId,
                threadMediaUrl ?? "-",
                localPlaybackMediaUrl ?? "-",
                type
              )
              self.setLiveMessageUploadProgressLocked(
                chatId: chatId, messageId: messageId, progress: 1.0, postDelta: false)
              self.postChangeLocked(
                reason: "chatMessageChanged",
                userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
              )
              self.postChatDeltaLocked(
                chatId: chatId, inserted: [], updated: [messageId], deleted: [],
                source: "optimistic")
              self.appendJournalLocked(
                event: "native-media-upload-ok",
                payload: [
                  "chatId": chatId,
                  "messageId": messageId,
                  "url": threadMediaUrl ?? "",
                ])
            }
          } else {
            let reason = uploadOutcome.reason ?? "upload_failed"
            let retryableReasons: Set<String> = [
              "upload_failed", "upload_timeout", "missing_upload_config", "invalid_upload_url",
            ]
            let shouldQueue = retryableReasons.contains(reason)

            self.queue.async {
              self.upsertLocalStatusLocked(
                chatId: chatId, messageId: messageId, status: shouldQueue ? "pending" : "error")
              self.appendJournalLocked(
                event: "native-media-upload-error",
                payload: [
                  "chatId": chatId,
                  "messageId": messageId,
                  "reason": reason,
                ])
              self.setLiveMessageUploadProgressLocked(
                chatId: chatId, messageId: messageId, progress: nil)
              self.postChangeLocked(
                reason: "chatMessageChanged",
                userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
              )
              self.postChangeLocked(
                reason: "messageStatusChanged",
                userInfo: [
                  "chatId": chatId,
                  "messageId": messageId,
                  "status": shouldQueue ? "pending" : "error",
                ])
              if shouldQueue {
                self.queueOutboundDraftLocked(
                  chatId: chatId, messageId: messageId, payload: localEffectivePayload,
                  reason: reason)
              } else {
                self.pendingOutboundDraftsByMessageId[messageId] = localEffectivePayload
              }
              self.canceledOutboundMessageIds.remove(messageId)
            }
            return
          }
        }

        if self.syncOnQueue({ self.canceledOutboundMessageIds.contains(messageId) }) {
          self.queue.async {
            self.setLiveMessageUploadProgressLocked(
              chatId: chatId, messageId: messageId, progress: nil)
            self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
            self.postChangeLocked(
              reason: "chatMessageChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
            )
            self.postChangeLocked(
              reason: "messageStatusChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "status": "error"])
            self.canceledOutboundMessageIds.remove(messageId)
          }
          return
        }

        if isSavedMessagesChat {
          localEffectivePayload["chatId"] = chatId
          localEffectivePayload["messageId"] = messageId
          localEffectivePayload["type"] = type
          localEffectivePayload["text"] = text

          self.queue.async {
            self.removeQueuedOutboundDraftLocked(
              chatId: chatId, messageId: messageId, dropDraft: false)
            self.pendingOutboundDraftsByMessageId[messageId] = localEffectivePayload
            self.appendJournalLocked(
              event: "native-send-saved-message-start",
              payload: [
                "chatId": chatId,
                "messageId": messageId,
                "type": type,
              ])
            NSLog(
              "[ChatEngine] sendMessage saved_messages direct chatId=%@ messageId=%@ type=%@",
              chatId, messageId, type)
          }

          self.sendSavedMessage(localEffectivePayload) { result in
            self.queue.async { [weak self] in
              guard let self else { return }
              let success = (result["success"] as? Bool) == true
              let statusCode = result["status"] as? Int ?? -1
              let failureReason =
                normalizedString(result["reason"])
                ?? normalizedString(result["error"])
                ?? "saved_message_send_failed"
              self.setLiveMessageUploadProgressLocked(
                chatId: chatId, messageId: messageId, progress: nil)
              if success {
                self.removeQueuedOutboundDraftLocked(
                  chatId: chatId, messageId: messageId, dropDraft: true)
              } else {
                self.removeQueuedOutboundDraftLocked(
                  chatId: chatId, messageId: messageId, dropDraft: false)
              }
              self.upsertLocalStatusLocked(
                chatId: chatId,
                messageId: messageId,
                status: success ? "sent" : "error"
              )
              self.appendJournalLocked(
                event: success ? "native-send-saved-message-ok" : "native-send-saved-message-error",
                payload: [
                  "chatId": chatId,
                  "messageId": messageId,
                  "status": statusCode,
                  "reason": success ? "ok" : failureReason,
                ])
              NSLog(
                "[ChatEngine] sendMessage saved_messages %@ chatId=%@ messageId=%@ status=%d reason=%@",
                success ? "OK" : "FAIL",
                chatId,
                messageId,
                statusCode,
                success ? "ok" : failureReason)
              self.postChangeLocked(
                reason: "chatMessageChanged",
                userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
              )
              self.postChangeLocked(
                reason: "messageStatusChanged",
                userInfo: [
                  "chatId": chatId,
                  "messageId": messageId,
                  "status": success ? "sent" : "error",
                ])
            }
          }
          return
        }

        var fullPayloadBase: [String: Any] = ["text": text]
        if let finalMediaUrl { fullPayloadBase["mediaUrl"] = finalMediaUrl }
        if let finalMediaKey { fullPayloadBase["mediaKey"] = finalMediaKey }
        if let finalFileName { fullPayloadBase["fileName"] = finalFileName }
        if let finalFileSize { fullPayloadBase["fileSize"] = finalFileSize }
        if let latitude { fullPayloadBase["latitude"] = latitude }
        if let longitude { fullPayloadBase["longitude"] = longitude }
        if let duration { fullPayloadBase["duration"] = duration }
        if let finalWidth { fullPayloadBase["width"] = finalWidth }
        if let finalHeight { fullPayloadBase["height"] = finalHeight }
        if let replyToId { fullPayloadBase["replyToId"] = replyToId }
        if let contact { fullPayloadBase["contact"] = contact }
        if let caption { fullPayloadBase["caption"] = caption }
        if let finalThumbnailBase64 {
          fullPayloadBase["thumbnailBase64"] = finalThumbnailBase64
        }
        if let viewOnce { fullPayloadBase["viewOnce"] = viewOnce }
        if let mediaTtlSeconds { fullPayloadBase["mediaTtlSeconds"] = mediaTtlSeconds }
        if let isVideoNote { fullPayloadBase["isVideoNote"] = isVideoNote }
        if let waveform { fullPayloadBase["waveform"] = waveform }
        if let stickerId { fullPayloadBase["stickerId"] = stickerId }
        if let stickerPackId { fullPayloadBase["stickerPackId"] = stickerPackId }
        if let stickerBundleFileName {
          fullPayloadBase["stickerBundleFileName"] = stickerBundleFileName
        }
        if let stickerEmoji { fullPayloadBase["emoji"] = stickerEmoji }
        let fullPayload = makeJSONSafeMap(fullPayloadBase)
        guard
          let fullPayloadData = try? JSONSerialization.data(
            withJSONObject: fullPayload, options: []),
          let fullPayloadString = String(data: fullPayloadData, encoding: .utf8)
        else {
          self.queue.async {
            self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
          }
          return
        }

        let encryptedContent: String
        do {
          let peerConfirmed = VibeSecureSessions.shared.isPeerConfirmed(chatId: chatId)
          if isHumanDirectMessage && !peerConfirmed {
            throw NSError(
              domain: "VibeSecure", code: 1,
              userInfo: [
                NSLocalizedDescriptionKey: "mls_not_ready — human DMs have no fallback transport"
              ])
          }
          let shouldSealWithMls =
            isHumanDirectMessage
            || (isGroup && !isChannel && VibeSecureSessions.isGroupSendEnabled && peerConfirmed)
          if shouldSealWithMls {
            guard
              let mlsSealed = VibeSecureSessions.shared.seal(
                chatId: chatId, plaintext: fullPayloadString)
            else {
              throw NSError(
                domain: "VibeSecure", code: 2,
                userInfo: [
                  NSLocalizedDescriptionKey: "mls_seal_failed — refusing weaker transport"
                ])
            }
            VibeSecureSessions.shared.rememberOwnPlaintext(
              fullPayloadString, messageId: messageId, envelope: mlsSealed)
            encryptedContent = mlsSealed
          } else {
            encryptedContent = fullPayloadString
          }
        } catch {
          self.queue.async {
            self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
            self.appendJournalLocked(
              event: "native-send-message-error",
              payload: [
                "chatId": chatId,
                "messageId": messageId,
                "reason": "encrypt_failed",
                "error": error.localizedDescription,
              ])
            self.postChangeLocked(
              reason: "messageStatusChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "status": "error"])
          }
          return
        }

        let pushPreview: String = {
          let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty {
            if trimmed.count <= 160 { return trimmed }
            return String(trimmed.prefix(159)) + "…"
          }
          switch type {
          case "image": return "Photo"
          case "video": return "Video"
          case "voice": return "Voice message"
          case "music": return "Audio"
          case "file": return "File"
          case "location": return "Location"
          case "contact": return "Contact"
          case "gif": return "GIF"
          case "sticker": return "Sticker"
          default: return ""
          }
        }()

        let pushKind: String = supportedTypes.contains(type) ? type : "text"

        let isRealE2EDM = isHumanDirectMessage

        var wirePayload: [String: Any] = [
          "id": messageId,
          "encryptedContent": encryptedContent,
          "timestamp": timestampMs,
          "type": type,
          "pushKind": pushKind,
          "mediaUrl": finalMediaUrl as Any? ?? NSNull(),
          "fileName": finalFileName as Any? ?? NSNull(),
          "latitude": latitude as Any? ?? NSNull(),
          "longitude": longitude as Any? ?? NSNull(),
        ]
        if !isRealE2EDM {
          wirePayload["pushPreview"] = pushPreview
        }
        if let replyToId, !replyToId.isEmpty {
          wirePayload["replyToId"] = replyToId
        }
        if let fromId = userId {
          wirePayload["fromId"] = fromId
        }
        if let peerAgentId, !peerAgentId.isEmpty {
          wirePayload["mentionedAgentId"] = peerAgentId
          if let agentText = payload["agentText"] as? String,
            !agentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            wirePayload["agentText"] = agentText
          } else {
            wirePayload["agentText"] = text
          }
        }
        if let agentMention = payload["agentMention"] as? Bool, agentMention {
          wirePayload["agentMention"] = true
          if let agentText = payload["agentText"] as? String {
            wirePayload["agentText"] = agentText
          }
        }
        if let mentionedAgentUsername = payload["mentionedAgentUsername"] as? String,
          !mentionedAgentUsername.isEmpty
        {
          wirePayload["mentionedAgentUsername"] = mentionedAgentUsername
          if let agentText = payload["agentText"] as? String {
            wirePayload["agentText"] = agentText
          }
        }
        let wireMetadata =
          (localEffectivePayload["metadata"] as? [String: Any]).flatMap { $0.isEmpty ? nil : $0 }
          ?? (metadata.isEmpty ? nil : metadata)
        if let wireMetadata {
          var cleaned = makeJSONSafeMap(wireMetadata)
          if let remote = finalMediaUrl, !self.isLocalMediaURI(remote) {
            cleaned["mediaUrl"] = remote
          } else if let existing = cleaned["mediaUrl"] as? String, self.isLocalMediaURI(existing) {
            cleaned.removeValue(forKey: "mediaUrl")
          }
          for key in ["localMediaUrl", "local_media_url", "extraLocalMediaUrls", "uploadProgress"] {
            cleaned.removeValue(forKey: key)
          }
          cleaned.removeValue(forKey: "mediaKey")
          cleaned.removeValue(forKey: "media_key")
          wirePayload["metadata"] = cleaned
        }

        if var message = localOptimisticRow["message"] as? [String: Any] {
          message["encryptedContent"] = encryptedContent
          localOptimisticRow["message"] = message
        }
        let threadOptimisticRow = localOptimisticRow
        let threadEffectivePayload = localEffectivePayload
        let threadWirePayload = wirePayload

        self.queue.async {
          if self.canceledOutboundMessageIds.contains(messageId) {
            self.setLiveMessageUploadProgressLocked(
              chatId: chatId, messageId: messageId, progress: nil)
            self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
            self.postChangeLocked(
              reason: "chatMessageChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "action": "updated"]
            )
            self.postChangeLocked(
              reason: "messageStatusChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "status": "error"])
            self.canceledOutboundMessageIds.remove(messageId)
            return
          }
          self.upsertLiveMessageRowLocked(
            chatId: chatId, messageId: messageId, row: threadOptimisticRow)
          self.postChatDeltaLocked(
            chatId: chatId, inserted: [], updated: [messageId], deleted: [],
            source: "optimistic")
          self.pendingOutboundDraftsByMessageId[messageId] = threadEffectivePayload

          guard let client = self.phoenixClient else {
            self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "pending")
            self.queueOutboundDraftLocked(
              chatId: chatId, messageId: messageId, payload: threadEffectivePayload,
              reason: "no_native_socket")
            self.scheduleReconnectLocked(reason: "send_no_socket")
            DispatchQueue.global(qos: .utility).async { [weak self] in
              self?.ensureNativeTransport(trigger: "send_no_socket")
            }
            self.postChangeLocked(
              reason: "messageStatusChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "status": "pending"])
            return
          }

          guard self.nativeJoinedChatIds.contains(chatId) else {
            self.joinNativeChatTopicIfNeededLocked(chatId: chatId)
            self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "pending")
            self.queueOutboundDraftLocked(
              chatId: chatId, messageId: messageId, payload: threadEffectivePayload,
              reason: "chat_not_joined"
            )
            self.scheduleReconnectLocked(reason: "send_chat_not_joined")
            DispatchQueue.global(qos: .utility).async { [weak self] in
              self?.ensureNativeTransport(trigger: "send_chat_not_joined")
            }
            self.postChangeLocked(
              reason: "messageStatusChanged",
              userInfo: ["chatId": chatId, "messageId": messageId, "status": "pending"])
            return
          }

          let ref = client.push(
            topic: self.chatTopic(for: chatId), event: "message", payload: threadWirePayload)
          self.nativePendingMessagePushRefs[ref] = (chatId: chatId, messageId: messageId)
          self.nativeMessagePushSentAtMs[ref] = self.nowMs()

          let timeoutRef = ref
          self.queue.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            guard let self = self else { return }
            self.nativeMessagePushSentAtMs.removeValue(forKey: timeoutRef)
            if let pending = self.nativePendingMessagePushRefs.removeValue(forKey: timeoutRef) {
              let timeoutProvider = self.bridgeProviderForChatLocked(chatId: pending.chatId)
              if let timeoutProvider {
                self.markVolatileBridgeSendErrorLocked(
                  chatId: pending.chatId,
                  messageId: pending.messageId,
                  reason: "send_timeout",
                  provider: timeoutProvider
                )
                self.scheduleReconnectLocked(reason: "bridge_send_timeout")
                DispatchQueue.global(qos: .utility).async { [weak self] in
                  self?.ensureNativeTransport(trigger: "bridge_send_timeout")
                }
                return
              }
              if let draft = self.pendingOutboundDraftsByMessageId[pending.messageId] {
                self.scheduleRetryableOutboundReplayLocked(
                  chatId: pending.chatId,
                  messageId: pending.messageId,
                  draft: draft,
                  reason: "send_timeout",
                  recycleTransport: true
                )
              }
              self.appendJournalLocked(
                event: "native-send-timeout",
                payload: [
                  "chatId": pending.chatId,
                  "messageId": pending.messageId,
                  "ref": timeoutRef,
                ])
            }
          }

          self.appendJournalLocked(
            event: "native-send-message",
            payload: [
              "chatId": chatId,
              "messageId": messageId,
              "ref": ref,
            ])
          self.postChangeLocked(
            reason: "messageStatusChanged", userInfo: ["chatId": chatId, "messageId": messageId])
        }
      }

      return [
        "accepted": true,
        "queued": true,
        "messageId": messageId,
        "state": "sending",
      ]
    }
  }

  func sendDeleteMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let messageId =
      normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
    guard let chatId, let messageId else {
      return ["accepted": false, "reason": "invalid_payload"]
    }
    if chatId == "saved_messages" {
      return sendDeleteSavedMessage(messageId: messageId)
    }
    if syncOnQueue({ isBridgeTextModeLocked() }) {
      return ["accepted": false, "reason": "delete_disabled_in_blackout"]
    }

    let forEveryone: Bool = {
      switch payload["forEveryone"] ?? payload["for_everyone"] {
      case let bool as Bool:
        return bool
      case let str as String:
        return ["true", "1", "yes"].contains(str.lowercased())
      case let num as NSNumber:
        return num.boolValue
      default:
        return true
      }
    }()

    return syncOnQueue {
      guard let client = phoenixClient else {
        return ["accepted": false, "reason": "no_native_socket"]
      }
      guard nativeJoinedChatIds.contains(chatId) else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        return ["accepted": false, "reason": "chat_not_joined"]
      }

      let ref = client.push(
        topic: chatTopic(for: chatId), event: "delete-message",
        payload: [
          "messageId": messageId,
          "forEveryone": forEveryone,
        ])
      nativePendingDeletePushRefs[ref] = (
        chatId: chatId, messageId: messageId, forEveryone: forEveryone)
      NSLog(
        "[DeleteTrace] accepted chatId=%@ messageId=%@ forEveryone=%@ ref=%@",
        chatId, messageId, forEveryone ? "true" : "false", ref)
      removeMessageIndicesLocked(chatId: chatId, messageId: messageId)
      markLiveMessageDeletedLocked(chatId: chatId, messageId: messageId)
      DispatchQueue.global(qos: .utility).async {
        VibeSecureSessions.shared.forget(messageId: messageId)
      }
      applyPinnedUpdateLocked(
        chatId: chatId,
        messageId: messageId,
        pinned: false,
        payload: [:],
        trigger: "delete_optimistic",
        refreshRemote: false
      )
      let snapshot = statusSnapshotLocked()
      postChangeLocked(
        reason: "chatMessageDeleted",
        userInfo: [
          "chatId": chatId,
          "messageId": messageId,
          "action": "deleted",
          "state": snapshot,
        ]
      )
      postChatDeltaLocked(
        chatId: chatId, inserted: [], updated: [], deleted: [messageId],
        source: "deleteOptimistic")
      NSLog(
        "[DeleteTrace] optimistic removal chatId=%@ messageId=%@ forEveryone=%@",
        chatId, messageId, forEveryone ? "true" : "false")
      appendJournalLocked(
        event: "native-send-delete-message",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
          "forEveryone": forEveryone,
          "ref": ref,
        ])
      return [
        "accepted": true,
        "transport": "native",
        "ref": ref,
        "chatId": chatId,
        "messageId": messageId,
        "forEveryone": forEveryone,
      ]
    }
  }

  private func sendDeleteSavedMessage(messageId: String) -> [String: Any] {
    let requestContext: (apiBase: URL, token: String, userId: String)? = syncOnQueue {
      guard let apiBase = apiBaseURLLocked(),
        let userId = normalizedString(
          getConfigValueLocked("userId") ?? getConfigValueLocked("myUserId"))
      else {
        return nil
      }
      let token = authHeaderTokenLocked() ?? ""
      let chatId = "saved_messages"

      cachedSavedMessagesResponse?.removeAll { row in
        normalizedString(
          row["id"] ?? row["messageId"] ?? row["message_id"]
            ?? row["original_message_id"] ?? row["originalMessageId"]) == messageId
      }
      removeMessageIndicesLocked(chatId: chatId, messageId: messageId)
      markLiveMessageDeletedLocked(chatId: chatId, messageId: messageId)
      let snapshot = statusSnapshotLocked()
      postChangeLocked(
        reason: "chatMessageDeleted",
        userInfo: [
          "chatId": chatId,
          "messageId": messageId,
          "action": "deleted",
          "state": snapshot,
        ])
      postChatDeltaLocked(
        chatId: chatId,
        inserted: [],
        updated: [],
        deleted: [messageId],
        source: "savedDeleteOptimistic"
      )
      appendJournalLocked(
        event: "saved-message-delete-optimistic",
        payload: ["chatId": chatId, "messageId": messageId])
      NSLog("[DeleteTrace] saved accepted messageId=%@ transport=http", messageId)
      return (apiBase, token, userId)
    }

    guard let requestContext else {
      return ["accepted": false, "reason": "saved_messages_not_ready"]
    }
    performSavedMessageDeleteRequest(
      apiBase: requestContext.apiBase,
      token: requestContext.token,
      userId: requestContext.userId,
      messageId: messageId,
      attempt: 1
    )
    return [
      "accepted": true,
      "transport": "http",
      "chatId": "saved_messages",
      "messageId": messageId,
      "forEveryone": false,
    ]
  }

  private func performSavedMessageDeleteRequest(
    apiBase: URL,
    token: String,
    userId: String,
    messageId: String,
    attempt: Int
  ) {
    let url =
      apiBase
      .appendingPathComponent("api")
      .appendingPathComponent("saved_messages")
      .appendingPathComponent(userId)
      .appendingPathComponent(messageId)
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
      [weak self] data, response, error in
      guard let self else { return }
      let status = (response as? HTTPURLResponse)?.statusCode ?? -1
      let success = error == nil && (200...299).contains(status)
      let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      NSLog(
        "[DeleteTrace] saved reply messageId=%@ attempt=%d status=%d success=%@ error=%@ body=%@",
        messageId,
        attempt,
        status,
        success ? "Y" : "N",
        error?.localizedDescription ?? "-",
        body.isEmpty ? "-" : body
      )
      if success {
        self.queue.async {
          self.appendJournalLocked(
            event: "saved-message-delete-reply",
            payload: [
              "messageId": messageId,
              "attempt": attempt,
              "status": status,
            ])
        }
        return
      }

      guard attempt < 3 else {
        self.queue.async {
          self.appendJournalLocked(
            event: "saved-message-delete-failed",
            payload: [
              "messageId": messageId,
              "attempts": attempt,
              "status": status,
              "error": error?.localizedDescription ?? "",
            ])
        }
        return
      }
      let retryDelay: TimeInterval = attempt == 1 ? 1.5 : 5.0
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + retryDelay) {
        [weak self] in
        self?.performSavedMessageDeleteRequest(
          apiBase: apiBase,
          token: token,
          userId: userId,
          messageId: messageId,
          attempt: attempt + 1
        )
      }
    }.resume()
  }

  func editMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let messageId =
      normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
    let nextText = normalizedString(payload["text"])
    guard let chatId, let messageId, let nextText else {
      return ["accepted": false, "reason": "invalid_payload"]
    }
    let trimmedText = nextText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else {
      return ["accepted": false, "reason": "empty_text"]
    }

    return syncOnQueue {
      guard let existingMessage = findMessagePayloadLocked(chatId: chatId, messageId: messageId)
      else {
        return ["accepted": false, "reason": "message_not_found"]
      }
      let peerUserIdHint =
        normalizedUpper(payload["peerUserId"] ?? payload["peer_user_id"])
        ?? chatPeerUserIdsByChatId[chatId]
      let explicitPeerAgentId = normalizedString(
        payload["peerAgentId"] ?? payload["peer_agent_id"])
      let peerAgentId = explicitPeerAgentId
        ?? resolvePeerAgentIdLocked(chatId: chatId, peerUserIdHint: peerUserIdHint)
      let isGroup =
        (payload["isGroup"] as? Bool) == true
        || (payload["isGroupOrChannel"] as? Bool) == true
      let isChannel = (payload["isChannel"] as? Bool) == true
      let isHumanDirectMessage =
        !isGroup && !isChannel && chatId != "saved_messages"
        && !isVolatileBridgeAgentChatLocked(chatId: chatId)
        && (peerAgentId ?? "").isEmpty
      if isHumanDirectMessage,
        !VibeSecureSessions.shared.isPeerConfirmed(chatId: chatId)
      {
        return ["accepted": false, "reason": "encryption_not_ready"]
      }

      let editedAt = Int64(nowMs())
      var fullPayloadBase: [String: Any] = [
        "text": trimmedText,
        "isEdited": true,
        "editedAt": editedAt,
      ]
      if let mediaUrl = normalizedString(existingMessage["mediaUrl"]) {
        fullPayloadBase["mediaUrl"] = mediaUrl
        fullPayloadBase["caption"] = trimmedText
      }
      if let fileName = normalizedString(existingMessage["fileName"]) {
        fullPayloadBase["fileName"] = fileName
      }
      if let duration = parseDoubleValue(existingMessage["duration"]) {
        fullPayloadBase["duration"] = duration
      }
      if let replyToId = normalizedString(existingMessage["replyToId"]) {
        fullPayloadBase["replyToId"] = replyToId
      }
      if let metadata = existingMessage["metadata"] as? [String: Any] {
        if let width = metadata["width"] { fullPayloadBase["width"] = width }
        if let height = metadata["height"] { fullPayloadBase["height"] = height }
        if let thumbnailBase64 = metadata["thumbnailBase64"] {
          fullPayloadBase["thumbnailBase64"] = thumbnailBase64
        }
        if let isVideoNote = metadata["isVideoNote"] {
          fullPayloadBase["isVideoNote"] = isVideoNote
        }
        if let waveform = metadata["waveform"] { fullPayloadBase["waveform"] = waveform }
      }
      let fullPayload = makeJSONSafeMap(fullPayloadBase)
      guard
        let payloadData = try? JSONSerialization.data(withJSONObject: fullPayload, options: []),
        let payloadString = String(data: payloadData, encoding: .utf8)
      else {
        return ["accepted": false, "reason": "payload_encode_failed"]
      }
      let encryptedContent: String
      do {
        let peerConfirmed = VibeSecureSessions.shared.isPeerConfirmed(chatId: chatId)
        let shouldSealWithMls =
          isHumanDirectMessage
          || (isGroup && !isChannel && VibeSecureSessions.isGroupSendEnabled && peerConfirmed)
        if shouldSealWithMls {
          guard
            let mlsSealed = VibeSecureSessions.shared.seal(
              chatId: chatId, plaintext: payloadString)
          else {
            throw NSError(
              domain: "VibeSecure", code: 2,
              userInfo: [
                NSLocalizedDescriptionKey: "mls_seal_failed — refusing weaker transport"
              ])
          }
          VibeSecureSessions.shared.rememberOwnPlaintext(
            payloadString, messageId: messageId, envelope: mlsSealed)
          encryptedContent = mlsSealed
        } else {
          encryptedContent = payloadString
        }
      } catch {
        appendJournalLocked(
          event: "native-edit-message-error",
          payload: [
            "chatId": chatId,
            "messageId": messageId,
            "reason": "encrypt_failed",
            "error": error.localizedDescription,
          ])
        return ["accepted": false, "reason": "encrypt_failed"]
      }

      guard let client = phoenixClient else {
        return ["accepted": false, "reason": "no_native_socket"]
      }
      guard nativeJoinedChatIds.contains(chatId) else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        return ["accepted": false, "reason": "chat_not_joined"]
      }
      let ref = client.push(
        topic: chatTopic(for: chatId), event: "edit-message",
        payload: [
          "messageId": messageId,
          "encryptedContent": encryptedContent,
          "editedAt": editedAt,
        ])
      nativePendingEditPushRefs[ref] = (chatId: chatId, messageId: messageId)
      appendJournalLocked(
        event: "native-send-edit-message",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
          "ref": ref,
        ])
      let result: [String: Any] = ["accepted": true, "transport": "native", "ref": ref]
      _ = applyNativeChatMutationEventLocked(
        chatId: chatId,
        event: "message-edited",
        payload: [
          "messageId": messageId,
          "encryptedContent": encryptedContent,
          "editedAt": editedAt,
        ]
      )
      postChangeLocked(
        reason: "chatMessageEdited", userInfo: ["chatId": chatId, "messageId": messageId])
      postChatDeltaLocked(
        chatId: chatId, inserted: [], updated: [messageId], deleted: [], source: "edit")
      return result
    }
  }

  func reportMediaOpened(chatId: String, messageId: String) {
    let chatId = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    let messageId = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty, !messageId.isEmpty else { return }
    queue.async { [weak self] in
      guard let self, let client = self.phoenixClient,
        self.nativeJoinedChatIds.contains(chatId)
      else { return }
      _ = client.push(
        topic: self.chatTopic(for: chatId),
        event: "media-opened",
        payload: ["messageId": messageId])
    }
  }

  func deleteMessage(_ payload: [String: Any]) -> [String: Any] {
    sendDeleteMessage(payload)
  }

  func reactToMessage(_ payload: [String: Any]) -> [String: Any] {
    guard let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"]),
      let messageId = normalizedString(payload["messageId"] ?? payload["message_id"]),
      let emoji = normalizedString(payload["emoji"]), !emoji.isEmpty
    else { return ["accepted": false, "reason": "invalid_payload"] }

    if chatId == "saved_messages" {
      return reactToSavedMessage(messageId: messageId, emoji: emoji)
    }

    return syncOnQueue {
      guard let client = phoenixClient else {
        return ["accepted": false, "reason": "no_native_socket"]
      }
      guard nativeJoinedChatIds.contains(chatId) else {
        joinNativeChatTopicIfNeededLocked(chatId: chatId)
        return ["accepted": false, "reason": "chat_not_joined"]
      }

      let optimistic = optimisticReactionBucketsLocked(
        chatId: chatId, messageId: messageId, emoji: emoji)
      _ = applyMessageEngagementLocked(
        chatId: chatId, messageId: messageId, reactions: optimistic, viewCount: nil)
      let ref = client.push(
        topic: chatTopic(for: chatId), event: "react-message",
        payload: ["messageId": messageId, "emoji": emoji])
      postChangeLocked(
        reason: "chatMessageReactionChanged",
        userInfo: ["chatId": chatId, "messageId": messageId])
      postChatDeltaLocked(
        chatId: chatId, inserted: [], updated: [messageId], deleted: [], source: "reaction")
      return ["accepted": true, "transport": "native", "ref": ref]
    }
  }

  private func reactToSavedMessage(messageId: String, emoji: String) -> [String: Any] {
    typealias Prepared = (
      apiBase: URL,
      token: String,
      previous: [[String: Any]],
      optimistic: [[String: Any]],
      generation: UInt64
    )
    let prepared: Prepared? = syncOnQueue {
      guard let apiBase = apiBaseURLLocked(),
        let existing = findMessagePayloadLocked(
          chatId: "saved_messages", messageId: messageId)
      else { return nil }

      let previous = existing["reactions"] as? [[String: Any]] ?? []
      let optimistic = optimisticReactionBucketsLocked(
        chatId: "saved_messages", messageId: messageId, emoji: emoji)
      let generation = (savedReactionGenerationByMessageId[messageId] ?? 0) &+ 1
      savedReactionGenerationByMessageId[messageId] = generation
      applySavedReactionBucketsLocked(messageId: messageId, reactions: optimistic)
      publishSavedReactionChangeLocked(messageId: messageId, source: "savedReactionOptimistic")
      return (apiBase, authHeaderTokenLocked() ?? "", previous, optimistic, generation)
    }

    guard let prepared else {
      return ["accepted": false, "reason": "saved_message_not_ready"]
    }
    performSavedMessageReactionRequest(
      apiBase: prepared.apiBase,
      token: prepared.token,
      messageId: messageId,
      emoji: emoji,
      previous: prepared.previous,
      optimistic: prepared.optimistic,
      generation: prepared.generation
    )
    return [
      "accepted": true,
      "transport": "http",
      "chatId": "saved_messages",
      "messageId": messageId,
    ]
  }

  private func performSavedMessageReactionRequest(
    apiBase: URL,
    token: String,
    messageId: String,
    emoji: String,
    previous: [[String: Any]],
    optimistic: [[String: Any]],
    generation: UInt64
  ) {
    let url =
      apiBase
      .appendingPathComponent("api")
      .appendingPathComponent("saved_messages")
      .appendingPathComponent(messageId)
      .appendingPathComponent("reaction")
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try? JSONSerialization.data(
      withJSONObject: ["emoji": emoji], options: [])

    ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
      [weak self] data, response, error in
      guard let self else { return }
      let status = (response as? HTTPURLResponse)?.statusCode ?? -1
      let success = error == nil && (200...299).contains(status)
      let canonical = data.flatMap(self.savedReactionBucketsFromResponse)
      self.queue.async {
        guard self.savedReactionGenerationByMessageId[messageId] == generation else { return }
        if success {
          self.applySavedReactionBucketsLocked(
            messageId: messageId, reactions: canonical ?? optimistic)
          self.publishSavedReactionChangeLocked(
            messageId: messageId, source: "savedReactionReply")
          self.appendJournalLocked(
            event: "saved-message-reaction-reply",
            payload: ["messageId": messageId, "status": status])
        } else {
          self.applySavedReactionBucketsLocked(messageId: messageId, reactions: previous)
          self.publishSavedReactionChangeLocked(
            messageId: messageId, source: "savedReactionRollback")
          self.appendJournalLocked(
            event: "saved-message-reaction-failed",
            payload: [
              "messageId": messageId,
              "status": status,
              "error": error?.localizedDescription ?? "",
            ])
        }
      }
    }.resume()
  }

  private func savedReactionBucketsFromResponse(_ data: Data) -> [[String: Any]]? {
    guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    if let reactions = body["reactions"] as? [[String: Any]] { return reactions }
    if let result = body["data"] as? [String: Any] {
      return result["reactions"] as? [[String: Any]]
    }
    return nil
  }

  private func applySavedReactionBucketsLocked(
    messageId: String, reactions: [[String: Any]]
  ) {
    _ = applyMessageEngagementLocked(
      chatId: "saved_messages", messageId: messageId, reactions: reactions, viewCount: nil)
    guard var cached = cachedSavedMessagesResponse else { return }
    for index in cached.indices where normalizedString(cached[index]["id"]) == messageId {
      cached[index]["reactions"] = reactions
      break
    }
    cachedSavedMessagesResponse = cached
  }

  private func publishSavedReactionChangeLocked(messageId: String, source: String) {
    postChangeLocked(
      reason: "chatMessageReactionChanged",
      userInfo: ["chatId": "saved_messages", "messageId": messageId])
    postChatDeltaLocked(
      chatId: "saved_messages",
      inserted: [],
      updated: [messageId],
      deleted: [],
      source: source)
  }

  func markMessagesViewed(_ payload: [String: Any]) -> [String: Any] {
    guard let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"]) else {
      return ["accepted": false, "reason": "invalid_chat"]
    }
    let messageIds = (payload["messageIds"] as? [Any] ?? []).compactMap(normalizedString)
    guard !messageIds.isEmpty else { return ["accepted": false, "reason": "empty_messages"] }

    return syncOnQueue {
      guard let client = phoenixClient, nativeJoinedChatIds.contains(chatId) else {
        return ["accepted": false, "reason": "chat_not_joined"]
      }
      let ref = client.push(
        topic: chatTopic(for: chatId), event: "messages-viewed",
        payload: ["messageIds": Array(Set(messageIds)).prefix(200).map { $0 }])
      return ["accepted": true, "transport": "native", "ref": ref]
    }
  }

  func reportMessage(
    _ payload: [String: Any], completion: @escaping (Bool, String?) -> Void
  ) -> [String: Any] {
    guard let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"]),
      let messageId = normalizedString(payload["messageId"] ?? payload["message_id"]),
      let reason = normalizedString(payload["reason"])
    else { return ["accepted": false, "reason": "invalid_payload"] }

    let context: (URL, String)? = syncOnQueue {
      guard let base = apiBaseURLLocked() else { return nil }
      return (base, authHeaderTokenLocked() ?? "")
    }
    guard let (base, token) = context else {
      return ["accepted": false, "reason": "missing_config"]
    }

    let url = base.appendingPathComponent("api").appendingPathComponent("chat")
      .appendingPathComponent(chatId).appendingPathComponent("messages")
      .appendingPathComponent(messageId).appendingPathComponent("report")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    var body: [String: Any] = [
      "reason": reason,
      "blockSender": parseBooleanLike(payload["blockSender"] ?? payload["block_sender"]) ?? false,
    ]
    if let details = normalizedString(payload["details"]), !details.isEmpty {
      body["details"] = details
    }
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
      [weak self] data, response, error in
      let status = (response as? HTTPURLResponse)?.statusCode ?? -1
      let success = error == nil && (200...299).contains(status)
      let responseReason: String? = data.flatMap {
        (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])
      }.flatMap { self?.normalizedString($0["error"] ?? $0["reason"]) }
      DispatchQueue.main.async { completion(success, error?.localizedDescription ?? responseReason) }
    }.resume()
    return ["accepted": true, "queued": true]
  }

  func clearChat(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    guard let chatId, !chatId.isEmpty else {
      return ["accepted": false, "reason": "invalid_chat"]
    }
    let localOnly =
      parseBooleanLike(
        payload["localOnly"] ?? payload["local_only"] ?? payload["skipRemoteDelete"]
          ?? payload["skip_remote_delete"])
      ?? false

    let requestContext: (URL?, String)?
    requestContext = syncOnQueue {
      let apiBase = apiBaseURLLocked()
      let token = authHeaderTokenLocked() ?? ""
      clearChatStateLocked(chatId: chatId, journalEvent: "native-chat-clear-local")
      return (apiBase, token)
    }

    if localOnly {
      return ["accepted": true, "localOnly": true, "chatId": chatId]
    }

    guard let requestContext, let apiBase = requestContext.0 else {
      return ["accepted": false, "reason": "missing_config", "chatId": chatId]
    }
    let token = requestContext.1

    var request = URLRequest(
      url: apiBase.appendingPathComponent("api").appendingPathComponent("chats")
        .appendingPathComponent(chatId).appendingPathComponent("clear"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] _, response, error in
      guard let self else { return }
      self.queue.async {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        if let error {
          self.appendJournalLocked(
            event: "native-chat-clear-error",
            payload: [
              "chatId": chatId,
              "error": error.localizedDescription,
            ])
          return
        }
        let success = (200...299).contains(statusCode)
        self.appendJournalLocked(
          event: success ? "native-chat-clear-ok" : "native-chat-clear-error",
          payload: [
            "chatId": chatId,
            "status": statusCode,
          ])
      }
    }.resume()

    return ["accepted": true, "queued": true, "chatId": chatId]
  }

  private func clearChatStateLocked(chatId: String, journalEvent: String) {
    historyRowsByChat.removeValue(forKey: chatId)
    historyFullyLoadedChats.remove(chatId)
    historyRowsRestoredFromCacheChats.remove(chatId)
    historyOlderExhaustedChats.remove(chatId)
    historyLoadingOlderChats.remove(chatId)
    historyHasMoreByChat.removeValue(forKey: chatId)
    historyNextCursorByChat.removeValue(forKey: chatId)
    historyNextCursorBoundaryByChat.removeValue(forKey: chatId)
    clearCachedHistoryRowsLocked(chatId: chatId)
    if chatId == "saved_messages" {
      cachedSavedMessagesResponse = nil
    }
    historyLoadingChats.remove(chatId)
    liveMessageRowsByChat.removeValue(forKey: chatId)
    deletedMessageIdsByChat.removeValue(forKey: chatId)
    receiptIndex.removeValue(forKey: chatId)
    localStatusIndex.removeValue(forKey: chatId)
    pendingOutboundQueueByChat.removeValue(forKey: chatId)
    nativeTypingStateByChatId.removeValue(forKey: chatId)
    peerTypingUserIdsByChatId.removeValue(forKey: chatId)
    agentProgressByChatId.removeValue(forKey: chatId)
    nativeRecordingStateByChatId.removeValue(forKey: chatId)
    pinnedMessagesByChatId.removeValue(forKey: chatId)
    pinnedFetchInFlightChatIds.remove(chatId)
    chatPeerUserIdsByChatId.removeValue(forKey: chatId)
    openChatChannels.removeValue(forKey: chatId)

    let draftIdsToRemove = pendingOutboundDraftsByMessageId.compactMap {
      (messageId, draft) -> String? in
      let draftChatId = normalizedString(draft["chatId"] ?? draft["chat_id"])
      return draftChatId == chatId ? messageId : nil
    }
    draftIdsToRemove.forEach { pendingOutboundDraftsByMessageId.removeValue(forKey: $0) }

    if nativeJoinedChatIds.remove(chatId) != nil, let client = phoenixClient {
      client.leave(topic: chatTopic(for: chatId))
    }

    feedCoreClearChatLocked(chatId: chatId)

    appendJournalLocked(event: journalEvent, payload: ["chatId": chatId])
    state["updatedAt"] = nowMs()
    postChangeLocked(reason: "chatRowsReloaded", userInfo: ["chatId": chatId])
    postChangeLocked(reason: "chatCleared", userInfo: ["chatId": chatId])
  }

  func blockUser(_ payload: [String: Any]) -> [String: Any] {
    let blockedUserId =
      normalizedString(
        payload["blockedUserId"] ?? payload["blocked_user_id"] ?? payload["peerUserId"]
          ?? payload["peer_user_id"])
    guard let blockedUserId, !blockedUserId.isEmpty else {
      return ["accepted": false, "reason": "invalid_user"]
    }

    let requestContext: (URL, String)?
    requestContext = syncOnQueue {
      guard let apiBase = apiBaseURLLocked() else { return nil }
      let token = authHeaderTokenLocked() ?? ""
      appendJournalLocked(
        event: "native-user-block-request",
        payload: ["blockedUserId": blockedUserId]
      )
      state["updatedAt"] = nowMs()
      return (apiBase, token)
    }

    guard let (apiBase, token) = requestContext else {
      return ["accepted": false, "reason": "missing_config"]
    }

    var request = URLRequest(
      url: apiBase.appendingPathComponent("api").appendingPathComponent("user")
        .appendingPathComponent("block"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try? JSONSerialization.data(
      withJSONObject: ["blocked_user_id": blockedUserId], options: [])

    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] _, response, error in
      guard let self else { return }
      self.queue.async {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        if let error {
          self.appendJournalLocked(
            event: "native-user-block-error",
            payload: [
              "blockedUserId": blockedUserId,
              "error": error.localizedDescription,
            ])
          return
        }
        let success = (200...299).contains(statusCode)
        self.appendJournalLocked(
          event: success ? "native-user-block-ok" : "native-user-block-error",
          payload: [
            "blockedUserId": blockedUserId,
            "status": statusCode,
          ])
        if success {
          self.postChangeLocked(
            reason: "userBlocked",
            userInfo: ["blockedUserId": blockedUserId]
          )
        }
      }
    }.resume()

    return ["accepted": true, "queued": true, "blockedUserId": blockedUserId]
  }

  func getPinnedMessages(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"]) ?? ""
    let shouldRefresh = parseBooleanLike(payload["refresh"]) ?? false
    guard !chatId.isEmpty else {
      VibeDebugLog.log("[ChatEngine][Pin] getPinnedMessages ignored: empty chatId")
      return ["chatId": "", "loading": false, "data": []]
    }

    return syncOnQueue {
      if chatId == "saved_messages" {
        pinnedMessagesByChatId[chatId] = []
        VibeDebugLog.log("[ChatEngine][Pin] getPinnedMessages skip saved_messages")
        return [
          "chatId": chatId,
          "loading": false,
          "data": [],
        ]
      }
      let hasCache = pinnedMessagesByChatId[chatId] != nil
      if !hasCache {
        pinnedMessagesByChatId[chatId] = []
      }
      if (shouldRefresh || !hasCache) && !pinnedFetchInFlightChatIds.contains(chatId) {
        fetchPinnedMessagesLocked(chatId: chatId, trigger: "on_demand")
      }
      let cachedPins = pinnedMessagesByChatId[chatId] ?? []
      let isLoading = pinnedFetchInFlightChatIds.contains(chatId)
      if shouldRefresh || !hasCache || isLoading || !cachedPins.isEmpty {
        VibeDebugLog.log(
          "[ChatEngine][Pin] getPinnedMessages chatId=%@ refresh=%@ hasCache=%@ loading=%@ count=%@",
          chatId,
          shouldRefresh ? "true" : "false",
          hasCache ? "true" : "false",
          isLoading ? "true" : "false",
          String(cachedPins.count)
        )
      }
      return [
        "chatId": chatId,
        "loading": isLoading,
        "data": cachedPins,
      ]
    }
  }

  func pinMessage(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let messageId = normalizedString(payload["messageId"] ?? payload["message_id"])
    let pinned = parseBooleanLike(payload["pinned"]) ?? true
    VibeDebugLog.log(
      "[ChatEngine][Pin] pinMessage request chatId=%@ messageId=%@ pinned=%@",
      chatId ?? "(nil)",
      messageId ?? "(nil)",
      pinned ? "true" : "false"
    )
    guard let chatId, !chatId.isEmpty else {
      return ["accepted": false, "reason": "invalid_chat"]
    }
    guard let messageId, !messageId.isEmpty else {
      return ["accepted": false, "reason": "invalid_message"]
    }

    let requestContext: (URL, String)?
    requestContext = syncOnQueue {
      guard let apiBase = apiBaseURLLocked() else { return nil }
      let token = authHeaderTokenLocked() ?? ""
      applyPinnedUpdateLocked(
        chatId: chatId,
        messageId: messageId,
        pinned: pinned,
        payload: [
          "messageId": messageId,
          "chatId": chatId,
          "timestamp": nowMs(),
        ],
        trigger: "local_pin_request",
        refreshRemote: false
      )
      state["updatedAt"] = nowMs()
      postChangeLocked(
        reason: "chatPinnedUpdated",
        userInfo: ["chatId": chatId, "messageId": messageId, "pinned": pinned]
      )
      return (apiBase, token)
    }

    guard let (apiBase, token) = requestContext else {
      NSLog(
        "[ChatEngine][Pin] pinMessage missing config chatId=%@ messageId=%@",
        chatId,
        messageId
      )
      return ["accepted": false, "reason": "missing_config", "chatId": chatId]
    }

    var request = URLRequest(
      url: apiBase.appendingPathComponent("api").appendingPathComponent("chat")
        .appendingPathComponent(chatId).appendingPathComponent("messages")
        .appendingPathComponent(messageId).appendingPathComponent("pin"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["pinned": pinned], options: [])

    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] _, response, error in
      guard let self else { return }
      self.queue.async {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        if let error {
          NSLog(
            "[ChatEngine][Pin] pinMessage network error chatId=%@ messageId=%@ pinned=%@ error=%@",
            chatId,
            messageId,
            pinned ? "true" : "false",
            error.localizedDescription
          )
          self.appendJournalLocked(
            event: "native-pin-message-error",
            payload: [
              "chatId": chatId,
              "messageId": messageId,
              "pinned": pinned,
              "error": error.localizedDescription,
            ])
          self.fetchPinnedMessagesLocked(chatId: chatId, trigger: "pin_error_reconcile")
          return
        }
        let success = (200...299).contains(statusCode)
        NSLog(
          "[ChatEngine][Pin] pinMessage response chatId=%@ messageId=%@ pinned=%@ status=%@ success=%@",
          chatId,
          messageId,
          pinned ? "true" : "false",
          String(statusCode),
          success ? "true" : "false"
        )
        self.appendJournalLocked(
          event: success ? "native-pin-message-ok" : "native-pin-message-error",
          payload: [
            "chatId": chatId,
            "messageId": messageId,
            "pinned": pinned,
            "status": statusCode,
          ])
        self.fetchPinnedMessagesLocked(chatId: chatId, trigger: "pin_request_complete")
      }
    }.resume()

    return [
      "accepted": true, "queued": true, "chatId": chatId, "messageId": messageId, "pinned": pinned,
    ]
  }

  func getChatProfileSummary(_ payload: [String: Any]) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    guard let chatId, !chatId.isEmpty else {
      return [
        "chatId": "",
        "historyLoaded": false,
        "totalMessages": 0,
        "mediaCount": 0,
        "fileCount": 0,
        "linkCount": 0,
        "recentFiles": [],
      ]
    }

    return syncOnQueue {
      _ = restoreCachedHistoryRowsLocked(chatId: chatId)
      let rows = mergedChatRowsLocked(chatId: chatId)
      var totalMessages = 0
      var mediaCount = 0
      var fileCount = 0
      var linkCount = 0
      var recentFiles: [String] = []

      for row in rows {
        guard normalizedString(row["kind"]) == "message" else { continue }
        guard let message = row["message"] as? [String: Any] else { continue }
        totalMessages += 1

        let type = normalizedString(message["type"])?.lowercased() ?? "text"
        let text = normalizedString(message["text"]) ?? ""
        let caption = normalizedString(message["caption"]) ?? ""
        let mediaUrl = normalizedString(message["mediaUrl"])
        let fileName = normalizedString(message["fileName"])

        let isMediaType = ["image", "gif", "video", "voice", "music"].contains(type)
        if isMediaType {
          mediaCount += 1
        }

        let isFileType = type == "file" || (!isMediaType && fileName != nil)
        if isFileType {
          fileCount += 1
          if let fileName, !fileName.isEmpty, recentFiles.count < 3 {
            recentFiles.append(fileName)
          }
        }

        let hasLink =
          containsLinkCandidate(text) || containsLinkCandidate(caption)
          || containsLinkCandidate(mediaUrl)
        if hasLink {
          let agentRegex = try? NSRegularExpression(
            pattern: "(/api/agent/document/|/uploads/agent-docs/)", options: [])
          let isAgentDoc =
            agentRegex?.firstMatch(
              in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)) != nil
            || agentRegex?.firstMatch(
              in: caption, options: [], range: NSRange(location: 0, length: caption.utf16.count))
              != nil
            || agentRegex?.firstMatch(
              in: mediaUrl ?? "", options: [],
              range: NSRange(location: 0, length: (mediaUrl ?? "").utf16.count)) != nil

          if !isAgentDoc {
            linkCount += 1
          }
        }
      }

      return [
        "chatId": chatId,
        "historyLoaded": historyRowsByChat[chatId] != nil,
        "totalMessages": totalMessages,
        "mediaCount": mediaCount,
        "fileCount": fileCount,
        "linkCount": linkCount,
        "recentFiles": recentFiles,
      ]
    }
  }

  func getJournal() -> [[String: Any]] {
    store.getJournal()
  }

  func clearJournal() -> [String: Any] {
    store.clearJournal()
    return syncOnQueue {
      journalEntryCount = 0
      state["updatedAt"] = nowMs()
      state["journalCount"] = 0
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "journalCleared", userInfo: [:])
      return snapshot
    }
  }

  private func publishChatRows(_ merged: [[String: Any]], for chatId: String) {
    publishedChatRowsLock.lock()
    publishedChatRowsByChat[chatId] = merged
    publishedChatRowsLock.unlock()
  }

  func getLiveMessageRow(_ payload: [String: Any]) -> [String: Any]? {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let messageId = normalizedString(payload["messageId"] ?? payload["message_id"])
    guard let chatId, let messageId else { return nil }
    return syncOnQueue {
      liveMessageRowsByChat[chatId]?[messageId]
    }
  }

  func getLiveMessageRows(_ payload: [String: Any]) -> [String: [String: Any]] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    guard let chatId else { return [:] }
    return syncOnQueue {
      liveMessageRowsByChat[chatId] ?? [:]
    }
  }

  private let publishedChatRowsLock = NSLock()
  private var publishedChatRowsByChat: [String: [[String: Any]]] = [:]

  func chatRows(chatId rawChatId: String, completion: @escaping ([[String: Any]]) -> Void) {
    guard let chatId = normalizedString(rawChatId), !chatId.isEmpty else {
      completion([])
      return
    }
    publishedChatRowsLock.lock()
    let published = publishedChatRowsByChat[chatId]
    publishedChatRowsLock.unlock()
    if let published {
      if Thread.isMainThread {
        completion(published)
      } else {
        DispatchQueue.main.async { completion(published) }
      }
      queue.async { [weak self] in
        guard let self else { return }
        _ = self.restoreCachedHistoryRowsLocked(chatId: chatId)
        self.restoreVolatileBridgeRowsIfNeededLocked(chatId: chatId)
        self.publishChatRows(self.mergedChatRowsLocked(chatId: chatId), for: chatId)
      }
      return
    }
    queue.async { [weak self] in
      guard let self else {
        DispatchQueue.main.async { completion([]) }
        return
      }
      _ = self.restoreCachedHistoryRowsLocked(chatId: chatId)
      self.restoreVolatileBridgeRowsIfNeededLocked(chatId: chatId)
      let merged = self.mergedChatRowsLocked(chatId: chatId)
      self.publishChatRows(merged, for: chatId)
      DispatchQueue.main.async { completion(merged) }
    }
  }

  func getChatRows(_ payload: [String: Any]) -> [[String: Any]] {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    guard let chatId else { return [] }
    if Thread.isMainThread {
      publishedChatRowsLock.lock()
      let published = publishedChatRowsByChat[chatId]
      publishedChatRowsLock.unlock()
      if let published {
        queue.async { [weak self] in
          guard let self else { return }
          _ = self.restoreCachedHistoryRowsLocked(chatId: chatId)
          self.restoreVolatileBridgeRowsIfNeededLocked(chatId: chatId)
          self.publishChatRows(self.mergedChatRowsLocked(chatId: chatId), for: chatId)
        }
        return published
      }
    }
    return syncOnQueue {
      _ = restoreCachedHistoryRowsLocked(chatId: chatId)
      restoreVolatileBridgeRowsIfNeededLocked(chatId: chatId)
      let merged = mergedChatRowsLocked(chatId: chatId)
      publishChatRows(merged, for: chatId)
      if merged.isEmpty {
        VibeDebugLog.log(
          "[EmptyTrace] getChatRows EMPTY chatId=%@ live=%d hist=%d progress=%@",
          String(chatId.suffix(12)),
          liveMessageRowsByChat[chatId]?.count ?? 0,
          historyRowsByChat[chatId]?.count ?? 0,
          agentProgressByChatId[chatId] != nil ? "active" : "cleared")
      }
      return merged
    }
  }

  func makeHomePreviewText(_ payload: [String: Any]) -> String? {
    guard let cacheKey = Self.homePreviewCacheKey(payload) else { return nil }
    if let memo = homePreviewMemo.value(for: cacheKey) { return memo }
    schedulePreviewDecrypt(cacheKey: cacheKey, payload: payload)
    return nil
  }

  private func schedulePreviewDecrypt(cacheKey: String, payload: [String: Any]) {
    guard homePreviewMemo.beginIfNotInFlight(cacheKey) else { return }
    queue.async { [weak self] in
      guard let self else { return }
      let text = self.homePreviewTextLocked(payload)
      self.homePreviewMemo.finish(cacheKey, value: text)
      guard text != nil else { return }
      self.postChangeLocked(
        reason: "chatPreviewDecrypted", userInfo: ["cacheKey": cacheKey])
    }
  }

  private func homePreviewTextLocked(_ payload: [String: Any]) -> String? {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"]) ?? "home_preview"
    let messageId =
      normalizedString(payload["id"] ?? payload["messageId"] ?? payload["message_id"]) ?? ""
    func giveUp(_ stage: String, isMine: Bool = false) -> String? {
      if ChatEngine.cryptoLogOnce("home-preview", messageId: messageId) {
        var line = chatEngineCryptoMeta(chatId: chatId, messageId: messageId, isMine: isMine)
        line["stage"] = stage
        VibeLog.warning("home preview has no plaintext", category: "crypto", metadata: line)
      }
      return nil
    }
    var rawMessage = payload
    if normalizedString(rawMessage["encryptedContent"] ?? rawMessage["encrypted_content"]) == nil,
      let content = normalizedString(rawMessage["content"])
    {
      rawMessage["encryptedContent"] = content
    }
    guard
      let row = buildHistoryRowsLocked(chatId: chatId, rawMessages: [rawMessage], allowMlsDecryption: true).first,
      let message = row["message"] as? [String: Any]
    else {
      return giveUp("no-row")
    }
    let isMine = (message["isMe"] as? Bool) == true
    if (message["decryptionFailed"] as? Bool) == true {
      return giveUp("decrypt-failed", isMine: isMine)
    }
    guard let text = normalizedString(message["plainContent"] ?? message["text"]) else {
      return giveUp("no-text", isMine: isMine)
    }
    guard !isLikelyHybridCiphertext(text) else {
      return giveUp("text-is-ciphertext", isMine: isMine)
    }
    return text
  }

  private static func homePreviewCacheKey(_ payload: [String: Any]) -> String? {
    let id =
      (payload["messageId"] as? String) ?? (payload["message_id"] as? String)
      ?? (payload["id"] as? String)
    guard let id, !id.isEmpty else { return nil }
    let body =
      (payload["encryptedContent"] as? String) ?? (payload["encrypted_content"] as? String)
      ?? (payload["content"] as? String) ?? (payload["text"] as? String) ?? ""
    return "\(id)|\(body.count)|\(body.suffix(16))"
  }

  private func expirePeerTypingLocked() {
    peerTypingExpiryScheduled = false
    let cutoff = Int64(nowMs()) - Self.peerTypingExpiryMs
    var stillTyping = false
    for (chatId, seenAt) in peerTypingSeenAtMsByChatId {
      let fresh = seenAt.filter { $0.value > cutoff }
      if fresh.count == seenAt.count {
        stillTyping = stillTyping || !fresh.isEmpty
        continue
      }
      if fresh.isEmpty {
        peerTypingSeenAtMsByChatId.removeValue(forKey: chatId)
        peerTypingUserIdsByChatId.removeValue(forKey: chatId)
      } else {
        peerTypingSeenAtMsByChatId[chatId] = fresh
        peerTypingUserIdsByChatId[chatId] = Set(fresh.keys)
        stillTyping = true
      }
      let typingUserIds = Array(peerTypingUserIdsByChatId[chatId] ?? []).sorted()
      postChangeLocked(
        reason: "peerTyping",
        userInfo: [
          "chatId": chatId,
          "messageId": typingUserIds.isEmpty ? "false" : "true",
          "typingUserIds": typingUserIds,
        ]
      )
    }
    if stillTyping { schedulePeerTypingExpiryLocked() }
  }

  private func schedulePeerTypingExpiryLocked() {
    guard !peerTypingExpiryScheduled else { return }
    peerTypingExpiryScheduled = true
    queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      self?.expirePeerTypingLocked()
    }
  }

  func typingUserIds(chatId: String?) -> [String] {
    guard let chatId = normalizedString(chatId), !chatId.isEmpty else { return [] }
    if let published = uiMirror.typingUserIds(chatId: chatId) { return published }
    return syncOnQueue {
      Array(peerTypingUserIdsByChatId[chatId] ?? []).sorted()
    }
  }

  func agentProgress(chatId: String?) -> [String: Any]? {
    guard let chatId = normalizedString(chatId), !chatId.isEmpty else { return nil }
    let now = Int64(nowMs())
    if let published = uiMirror.agentProgress(chatId: chatId) {
      return published?.activePayload(nowMs: now)
    }
    return syncOnQueue { () -> [String: Any]? in
      guard let state = agentProgressByChatId[chatId] else { return nil }
      return ChatEngineAgentProgressSnapshot(
        label: state.label,
        tool: state.tool,
        status: state.status,
        updatedAtMs: state.updatedAtMs
      ).activePayload(nowMs: now)
    }
  }

  func isWaitingForSecureSession(chatId: String?) -> Bool {
    guard let chatId = normalizedString(chatId), !chatId.isEmpty else { return false }
    return uiMirror.isWaitingForSecureSession(chatId: chatId) ?? false
  }

  func bridgeRunIsActive(chatId: String?) -> Bool {
    guard let chatId = normalizedString(chatId), !chatId.isEmpty else { return false }
    if let published = uiMirror.bridgeRunIsActive(
      chatId: chatId, nowMs: Int64(nowMs()), graceMs: Self.agentTurnRunningGraceMs)
    {
      return published
    }
    return syncOnQueue {
      if agentProgressByChatId[chatId] != nil { return true }
      let now = Int64(nowMs())
      if let lastRunningAt = agentTurnRunningAtMsByChatId[chatId],
        now - lastRunningAt < Self.agentTurnRunningGraceMs
      {
        return true
      }
      return agentBridgeAskByRequestId.values.contains { payload in
        (normalizedString(payload["chatId"]) ?? "") == chatId
      }
    }
  }

  private struct PublishedChatFlags {
    var loaded = false
    var loading = false
  }
  private let publishedChatFlagsLock = NSLock()
  private var publishedChatFlags: [String: PublishedChatFlags] = [:]
  private var publishedChatFlagsReady = false

  private func publishChatFlags(for chatId: String) {
    var flags = PublishedChatFlags()
    flags.loaded = historyFullyLoadedChats.contains(chatId)
    flags.loading =
      historyLoadingChats.contains(chatId) || historyLoadingOlderChats.contains(chatId)
    publishedChatFlagsLock.lock()
    publishedChatFlags[chatId] = flags
    publishedChatFlagsReady = true
    publishedChatFlagsLock.unlock()
  }

  private func publishedChatFlags(for chatId: String) -> PublishedChatFlags? {
    publishedChatFlagsLock.lock()
    defer { publishedChatFlagsLock.unlock() }
    guard publishedChatFlagsReady else { return nil }
    return publishedChatFlags[chatId] ?? PublishedChatFlags()
  }

  func isChatHistoryLoaded(chatId: String) -> Bool {
    if Thread.isMainThread, let flags = publishedChatFlags(for: chatId) {
      queue.async { [weak self] in
        guard let self else { return }
        _ = self.restoreCachedHistoryRowsLocked(chatId: chatId)
        self.publishChatFlags(for: chatId)
      }
      return flags.loaded
    }
    return syncOnQueue {
      _ = restoreCachedHistoryRowsLocked(chatId: chatId)
      publishChatFlags(for: chatId)
      return historyFullyLoadedChats.contains(chatId)
    }
  }

  func isChatHistoryLoading(chatId: String) -> Bool {
    guard let normalized = normalizedString(chatId), !normalized.isEmpty else { return false }
    if Thread.isMainThread, let flags = publishedChatFlags(for: normalized) {
      queue.async { [weak self] in self?.publishChatFlags(for: normalized) }
      return flags.loading
    }
    return syncOnQueue {
      publishChatFlags(for: normalized)
      return historyLoadingChats.contains(normalized)
        || historyLoadingOlderChats.contains(normalized)
    }
  }

  func hasOlderChatHistory(chatId: String) -> Bool {
    syncOnQueue {
      guard let chatId = normalizedString(chatId), !chatId.isEmpty,
        chatId != "saved_messages",
        !isBuiltInAgentChatId(chatId),
        !historyOlderExhaustedChats.contains(chatId),
        let boundary = oldestHistoryBoundaryLocked(chatId: chatId)
      else { return false }

      let hasStoredOlder: Bool
      if let userId = chatHistoryCacheUserIdLocked(), messageStore.isAvailable {
        hasStoredOlder = messageStore.hasOlderMessages(
          userId: userId,
          chatId: chatId,
          beforeTs: boundary.timestampMs,
          beforeMessageId: boundary.messageId
        )
      } else {
        hasStoredOlder = false
      }
      return hasStoredOlder || historyHasMoreByChat[chatId] != false
    }
  }

  @discardableResult
  func loadOlderChatHistory(chatId: String) -> Bool {
    syncOnQueue {
      guard let chatId = normalizedString(chatId), !chatId.isEmpty else { return false }
      return loadOlderChatHistoryLocked(chatId: chatId)
    }
  }

  func isTyping(_ payload: [String: Any]) -> Bool {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    guard let chatId else { return false }
    return syncOnQueue {
      !(peerTypingUserIdsByChatId[chatId]?.isEmpty ?? true)
    }
  }

  func isLiveMessageDeleted(_ payload: [String: Any]) -> Bool {
    let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"])
    let messageId = normalizedString(payload["messageId"] ?? payload["message_id"])
    guard let chatId, let messageId else { return false }
    return syncOnQueue {
      deletedMessageIdsByChat[chatId]?.contains(messageId) == true
    }
  }

  func resolveDisplayStatus(
    chatId: String?,
    messageId: String?,
    rawStatus: String?,
    isMe: Bool,
    peerUserId: String?
  ) -> String? {
    let normalizedRaw = normalizedString(rawStatus)?.lowercased()
    guard isMe else { return normalizedRaw }

    if normalizedRaw == "read" { return "read" }

    if Thread.isMainThread, let chatId, let messageId,
      let mirrored = uiMirror.displayStatusInputs(
        chatId: chatId, messageId: messageId, peerUserId: normalizedUpper(peerUserId))
    {
      return Self.resolveDisplayStatus(
        normalizedRaw: normalizedRaw, receiptStatus: mirrored.receipt,
        localStatus: mirrored.local, peerOnline: mirrored.peerOnline)
    }
    return syncOnQueue {
      var receiptStatus: String?
      var localStatus: String?
      if let chatId, let messageId {
        receiptStatus = receiptIndex[chatId]?[messageId]
        localStatus = localStatusIndex[chatId]?[messageId]
      }
      let peerOnline = normalizedUpper(peerUserId).map { onlineUsers.contains($0) } ?? false
      return Self.resolveDisplayStatus(
        normalizedRaw: normalizedRaw, receiptStatus: receiptStatus, localStatus: localStatus,
        peerOnline: peerOnline)
    }
  }

  private static func resolveDisplayStatus(
    normalizedRaw: String?, receiptStatus: String?, localStatus: String?, peerOnline: Bool
  ) -> String? {
      if receiptStatus == "read" { return "read" }
      if receiptStatus == "delivered" { return "delivered" }
      if normalizedRaw == "delivered" { return "delivered" }

      if let localStatus {
        switch localStatus {
        case "read":
          return "read"
        case "delivered":
          return "delivered"
        case "error":
          return "error"
        case "sent":
          return peerOnline ? "delivered" : "sent"
        case "pending", "sending":
          if normalizedRaw == nil || normalizedRaw == "sending" || normalizedRaw == "pending" {
            return localStatus
          }
        default:
          break
        }
      }

      if normalizedRaw == "sent", peerOnline { return "delivered" }
      return normalizedRaw
  }

  private func sendReceipt(
    _ payload: [String: Any],
    status: String,
    eventName: String,
    wireEvent: String
  ) -> [String: Any] {
    let chatId = normalizedString(payload["chatId"]) ?? normalizedString(payload["chat_id"])
    let messageId =
      normalizedString(payload["messageId"]) ?? normalizedString(payload["message_id"])
    guard let chatId, let messageId else { return getStatus() }
    return syncOnQueue {
      upsertReceiptLocked(chatId: chatId, messageId: messageId, status: status)

      var accepted = false
      var ref: String?
      if let client = phoenixClient,
        nativeJoinedChatIds.contains(chatId),
        (state["connected"] as? Bool) == true
      {
        ref = client.push(
          topic: chatTopic(for: chatId), event: wireEvent, payload: ["messageId": messageId])
        accepted = true
        appendJournalLocked(
          event: "native-\(eventName)-push",
          payload: [
            "chatId": chatId,
            "messageId": messageId,
            "ref": ref as Any,
          ])
      }

      appendJournalLocked(event: eventName, payload: payload)
      let snapshot = statusSnapshotLocked()
      postChangeLocked(
        reason: "messageStatusChanged",
        userInfo: ["chatId": chatId, "messageId": messageId, "status": status]
      )
      var out = snapshot
      out["accepted"] = accepted
      out["transport"] = accepted ? "native" : "shadow"
      if let ref { out["ref"] = ref }
      return out
    }
  }

  private func upsertReceiptLocked(chatId: String, messageId: String, status: String) {
    var chatMap = receiptIndex[chatId] ?? [:]
    let current = chatMap[messageId]
    let next = strongerStatus(current, status)
    chatMap[messageId] = next
    receiptIndex[chatId] = chatMap
    state["receiptCount"] = receiptIndex.values.reduce(0) { $0 + $1.count }
    state["updatedAt"] = nowMs()
  }

  private func upsertLocalStatusLocked(
    chatId: String,
    messageId: String,
    status: String,
    allowDowngrade: Bool = false
  ) {
    var chatMap = localStatusIndex[chatId] ?? [:]
    let current = chatMap[messageId]
    let next = allowDowngrade ? status : strongerDisplayStatus(current, status)
    chatMap[messageId] = next
    localStatusIndex[chatId] = chatMap
    var rowChanged = setLiveMessageStatusLocked(chatId: chatId, messageId: messageId, status: next)
    if next == "sent" || next == "delivered" || next == "read" || next == "error" {
      rowChanged = setLiveMessageUploadProgressLocked(
        chatId: chatId, messageId: messageId, progress: nil, postDelta: false) || rowChanged
    }
    state["localStatusCount"] = localStatusIndex.values.reduce(0) { $0 + $1.count }
    state["updatedAt"] = nowMs()
    if rowChanged {
      postChatDeltaLocked(
        chatId: chatId, inserted: [], updated: [messageId], deleted: [], source: "status")
    }
  }

  private func removeMessageIndicesLocked(chatId: String, messageId: String) {
    if var receiptChatMap = receiptIndex[chatId] {
      receiptChatMap.removeValue(forKey: messageId)
      if receiptChatMap.isEmpty {
        receiptIndex.removeValue(forKey: chatId)
      } else {
        receiptIndex[chatId] = receiptChatMap
      }
    }
    if var localChatMap = localStatusIndex[chatId] {
      localChatMap.removeValue(forKey: messageId)
      if localChatMap.isEmpty {
        localStatusIndex.removeValue(forKey: chatId)
      } else {
        localStatusIndex[chatId] = localChatMap
      }
    }
    state["receiptCount"] = receiptIndex.values.reduce(0) { $0 + $1.count }
    state["localStatusCount"] = localStatusIndex.values.reduce(0) { $0 + $1.count }
    state["updatedAt"] = nowMs()
  }

  private func strongerStatus(_ lhs: String?, _ rhs: String) -> String {
    func rank(_ value: String?) -> Int {
      switch value {
      case "read": return 2
      case "delivered": return 1
      default: return 0
      }
    }
    return rank(rhs) >= rank(lhs) ? rhs : (lhs ?? rhs)
  }

  private func strongerDisplayStatus(_ lhs: String?, _ rhs: String) -> String {
    func rank(_ value: String?) -> Int {
      switch value {
      case "read": return 6
      case "delivered": return 5
      case "sent": return 4
      case "error": return 3
      case "sending": return 2
      case "pending": return 1
      default: return 0
      }
    }
    return rank(rhs) >= rank(lhs) ? rhs : (lhs ?? rhs)
  }

  private func defaultAgentProgressLabel(tool: String?) -> String {
    switch tool {
    case "search_google":
      return "Thinking..."
    case "analyze_image":
      return "Thinking..."
    case "analyze_document":
      return "Thinking..."
    case "create_document":
      return "Updating file..."
    case "find_rows":
      return "Thinking..."
    case "edit_rows":
      return "Updating file..."
    case "delete_rows":
      return "Updating file..."
    case "export_rows":
      return "Updating file..."
    case "delete_document":
      return "Updating file..."
    case "pin_message":
      return "Pinning..."
    default:
      return "Typing..."
    }
  }

  private func setAgentProgressLocked(
    chatId: String,
    label: String?,
    tool: String?,
    status: String
  ) {
    let normalizedStatus =
      status
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .isEmpty
      ? "running"
      : status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    let shouldClear = Set([
      "done", "complete", "completed", "idle", "stopped", "stop", "error", "failed",
    ]).contains(normalizedStatus)

    if shouldClear {
      clearAgentProgressLocked(
        chatId: chatId, status: normalizedStatus, reason: "setProgress(status=\(normalizedStatus))")
      return
    }

    let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let trimmedToolValue = tool?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let normalizedTool = trimmedToolValue.isEmpty ? nil : trimmedToolValue
    let resolvedLabel =
      trimmedLabel.isEmpty ? defaultAgentProgressLabel(tool: normalizedTool) : trimmedLabel
    let next = AgentProgressState(
      label: resolvedLabel,
      tool: normalizedTool,
      status: normalizedStatus,
      updatedAtMs: Int64(nowMs())
    )
    let previous = agentProgressByChatId[chatId]
    guard previous != next else { return }
    agentProgressByChatId[chatId] = next
    emitAgentProgressChangeLocked(chatId: chatId, state: next)
  }

  private func clearAgentProgressLocked(
    chatId: String, status: String = "done", reason: String = "-"
  ) {
    guard let previous = agentProgressByChatId.removeValue(forKey: chatId) else { return }
    VibeDebugLog.log(
      "[EmptyTrace] clearAgentProgress chatId=%@ reason=%@ hadLabel=%@ status=%@",
      String(chatId.suffix(12)), reason, previous.label, status)
    let normalizedStatus =
      status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "done"
      : status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    emitAgentProgressChangeLocked(
      chatId: chatId, state: nil, previous: previous, status: normalizedStatus)
  }

  // MARK: - Live agent streaming (bridge)
  func reconcileAgentBridgeStatus(_ status: AgentBridgeStatus, source: String) {
    queue.async { [weak self] in
      self?.reconcileAgentBridgeStatusLocked(status, source: source)
    }
  }

  func ingestLanBridgeEvent(type: String, payload: [String: Any]) {
    queue.async { [weak self] in
      self?.ingestLanBridgeEventLocked(type: type, payload: payload)
    }
  }

  private func ingestLanBridgeEventLocked(type: String, payload: [String: Any]) {
    let kind = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch kind {
    case "history_result", "agent-bridge-history":
      applyLanHistoryResultLocked(payload)
    case "progress":
      ingestLanProgressLocked(payload)
    case "result":
      if let taskId = normalizedString(payload["taskId"] ?? payload["task_id"]),
        let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"]),
        let provider = normalizedString(payload["provider"])
      {
        let key = "\(provider):\(chatId):\(taskId)"
        lanProgressLinesByTask.removeValue(forKey: key)
        cloudProgressAtMsByTask.removeValue(forKey: "\(chatId):\(taskId)")
        let exitStatus = Int(parseLongValue(payload["exitStatus"] ?? payload["exit_status"]) ?? 0)
        let terminalStatus = exitStatus == 0 ? "done" : (exitStatus == 130 ? "stopped" : "error")
        if normalizedString(payload["teamRunId"] ?? payload["team_run_id"]) == nil {
          settleAgentBridgeTaskLocked(
            chatId: chatId,
            taskId: taskId,
            terminalStatus: terminalStatus,
            reason: "lan-result"
          )
        }
      }
    case "status", "bridge_status":
      DispatchQueue.main.async {
        AgentPairingService.ingestLanStatusSnapshot(payload)
      }
    default:
      break
    }
  }

  private func reconcileAgentBridgeStatusLocked(
    _ status: AgentBridgeStatus,
    source: String
  ) {
    guard status.connected else { return }

    let activeTaskKeys = Set(status.runningTasks.compactMap { task -> String? in
      let chatId = task.chatId.trimmingCharacters(in: .whitespacesAndNewlines)
      let taskId = task.taskId.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !chatId.isEmpty, !taskId.isEmpty else { return nil }
      return "\(chatId)|\(taskId)"
    })
    let activeTeamKeys = Set(status.runningTasks.compactMap { task -> String? in
      let chatId = task.chatId.trimmingCharacters(in: .whitespacesAndNewlines)
      let teamRunId = task.teamRunId?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !chatId.isEmpty, !teamRunId.isEmpty else { return nil }
      return "\(chatId)|\(teamRunId)"
    })

    var staleRows: [(chatId: String, messageId: String, taskId: String?, teamRunId: String?)] = []
    for (chatId, perChat) in liveMessageRowsByChat {
      for (messageId, row) in perChat {
        guard let message = row["message"] as? [String: Any],
          let metadata = message["metadata"] as? [String: Any]
        else { continue }
        let runtime = (metadata["agentRuntime"] as? [String: Any]) ?? [:]
        let isStreaming =
          (message["isStreaming"] as? Bool) == true
          || (metadata["isStreaming"] as? Bool) == true
        let runtimeStatus = (normalizedString(runtime["status"]) ?? "").lowercased()
        let runtimeIsLive = ["running", "starting", "pending", "active", "streaming"]
          .contains(runtimeStatus)
        guard isStreaming || runtimeIsLive else { continue }

        let taskId = normalizedString(
          runtime["taskId"] ?? runtime["task_id"]
            ?? metadata["agentTaskId"] ?? metadata["agent_task_id"])
        let teamRunId = normalizedString(runtime["teamRunId"] ?? runtime["team_run_id"])
        guard taskId != nil || teamRunId != nil else { continue }
        if let taskId, activeTaskKeys.contains("\(chatId)|\(taskId)") { continue }
        if let teamRunId, activeTeamKeys.contains("\(chatId)|\(teamRunId)") { continue }
        staleRows.append((chatId, messageId, taskId, teamRunId))
      }
    }

    guard !staleRows.isEmpty else { return }
    var changedChats = Set<String>()
    var changedIdsByChat: [String: [String]] = [:]
    for stale in staleRows {
      if settleLiveBridgeMessageLocked(
        chatId: stale.chatId,
        messageId: stale.messageId,
        terminalStatus: "done"
      ) {
        changedChats.insert(stale.chatId)
        changedIdsByChat[stale.chatId, default: []].append(stale.messageId)
      }
      if let taskId = stale.taskId {
        removeBridgeTaskTrackingLocked(chatId: stale.chatId, taskId: taskId)
      }
      if let teamRunId = stale.teamRunId,
        liveStreamTaskRowIdByChatId[stale.chatId]?["team:\(teamRunId)"] == stale.messageId
      {
        liveStreamTaskRowIdByChatId[stale.chatId]?.removeValue(forKey: "team:\(teamRunId)")
      }
    }

    for chatId in changedChats {
      let chatStillActive = status.runningTasks.contains {
        $0.chatId.trimmingCharacters(in: .whitespacesAndNewlines) == chatId
      }
      if !chatStillActive {
        agentTurnRunningAtMsByChatId.removeValue(forKey: chatId)
        clearAgentProgressLocked(
          chatId: chatId,
          status: "done",
          reason: "bridgeStatus(\(source))"
        )
      }
      storeMergedChatHistoryIfLoadedLocked(chatId: chatId)
      postChangeLocked(
        reason: "chatRowsReloaded",
        userInfo: ["chatId": chatId, "state": statusSnapshotLocked()]
      )
      postChatDeltaLocked(
        chatId: chatId, inserted: [], updated: changedIdsByChat[chatId] ?? [], deleted: [],
        source: "bridgeStatus")
    }
    NSLog(
      "[AgentStatus] reconciled source=%@ staleRows=%d chats=%d activeTasks=%d",
      source, staleRows.count, changedChats.count, status.runningTasks.count)
  }

  private func applyLanHistoryResultLocked(_ payload: [String: Any]) {
    guard let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"]) else { return }
    let requestId = normalizedString(payload["requestId"]) ?? ""
    if !requestId.isEmpty { lanHistoryPendingRequestIds.remove(requestId) }
    applyAgentBridgeHistoryResultLocked(chatId: chatId, payload: payload, transport: "lan")
  }

  private func applyAgentBridgeHistoryResultLocked(
    chatId: String, payload: [String: Any], transport: String
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    agentBridgeHistoryByChat[chatId] = payload
    let mode = normalizedString(payload["mode"]) ?? "list"
    let provider = normalizedString(payload["provider"]) ?? ""
    if !provider.isEmpty {
      if mode == "list" {
        agentBridgeHistoryListByChatProvider["\(chatId)|\(provider.lowercased())"] = payload
      }
    }
    let requestId = normalizedString(payload["requestId"]) ?? ""
    if transport == "lan" {
      NSLog(
        "[LanBridge] history %@ reply over LAN req=%@ chat=%@ provider=%@",
        mode, String(requestId.prefix(8)), String(chatId.prefix(12)), provider)
    }

    let okFlag = payload["ok"]
    let ok: Bool = {
      if let b = okFlag as? Bool { return b }
      if let n = okFlag as? NSNumber { return n.boolValue }
      if let s = okFlag as? String { return s.lowercased() != "false" && s != "0" }
      return true
    }()
    let message = (normalizedString(payload["message"]) ?? "").lowercased()
    let isNoCurrent =
      !ok
      && (message.contains("no_current_session") || message.contains("no session") || message.isEmpty)
    if isNoCurrent, mode == "detail", payload["session"] == nil {
      noCurrentSessionUntilMsByChatId[chatId] = Int64(nowMs()) + 90_000
      currentSessionLoadInflightByChatId.removeValue(forKey: chatId)
      pendingBridgeSessionIngestByRequestId.removeValue(forKey: requestId)
      NSLog(
        "[ChatEngine][BridgeMount] no_current_session chat=%@ msg=%@ transport=%@ — suppress polls 90s",
        String(chatId.suffix(12)),
        message.isEmpty ? "<empty>" : message,
        transport
      )
      postChangeLocked(
        reason: "agentBridgeHistory",
        userInfo: [
          "chatId": chatId,
          "provider": provider,
          "mode": mode,
          "requestId": requestId,
          "message": "no_current_session",
        ]
      )
      return
    }
    if ok { noCurrentSessionUntilMsByChatId.removeValue(forKey: chatId) }
    if mode == "detail" {
      var ingestProvider: String?
      if let target = pendingBridgeSessionIngestByRequestId.removeValue(forKey: requestId) {
        ingestProvider = provider.isEmpty ? target.provider : provider
      } else if let live = liveBridgeSessionIngestByChatId[chatId],
        live.requestId == requestId
      {
        ingestProvider = provider.isEmpty ? live.provider : provider
      }
      if let ingestProvider {
        if payload["session"] is [String: Any] {
          ingestAgentBridgeSessionLocked(
            chatId: chatId,
            provider: ingestProvider,
            payload: payload
          )
          currentSessionLoadInflightByChatId.removeValue(forKey: chatId)
          sessionLoadInflightByChatId.removeValue(forKey: chatId)
        } else if var paging = bridgeSessionPagingByChatId[chatId] {
          paging.loadingOlder = false
          bridgeSessionPagingByChatId[chatId] = paging
          currentSessionLoadInflightByChatId.removeValue(forKey: chatId)
        }
      }
    }
    postChangeLocked(
      reason: "agentBridgeHistory",
      userInfo: [
        "chatId": chatId,
        "provider": provider,
        "mode": mode,
        "requestId": requestId,
      ]
    )
  }

  private func ingestLanProgressLocked(_ payload: [String: Any]) {
    guard let chatId = normalizedString(payload["chatId"] ?? payload["chat_id"]),
      let provider = normalizedString(payload["provider"]),
      let taskId = normalizedString(payload["taskId"] ?? payload["task_id"])
    else { return }
    let seq = parseLongValue(payload["sequence"]) ?? 0
    let key = "\(provider):\(chatId):\(taskId)"
    let line = normalizedString(payload["line"]) ?? ""
    if !line.isEmpty {
      var lines = lanProgressLinesByTask[key] ?? []
      lines.append(line)
      if lines.count > 400 { lines = Array(lines.suffix(400)) }
      lanProgressLinesByTask[key] = lines
    }
    agentTurnRunningAtMsByChatId[chatId] = Int64(nowMs())

    let taskKey = "\(chatId):\(taskId)"
    if let lastCloud = cloudProgressAtMsByTask[taskKey],
      Int64(nowMs()) - lastCloud < Self.lanReclaimAfterCloudSilenceMs
    {
      return
    }

    if let prev = lanProgressSeqByTask[key], seq > 0, seq <= prev {
      return  // already applied (cloud or earlier LAN)
    }
    if seq > 0 {
      lanProgressSeqByTask[key] = Int(seq)
    }
    let accumulated = (lanProgressLinesByTask[key] ?? []).joined(separator: "\n")
    let displayText = Self.lightweightStreamText(from: accumulated, provider: provider)
    let agentUserId = Self.bridgeAgentUserId(forProvider: provider)
    let streamId = "lan-\(taskId)"
    let existingNodes =
      ((liveMessageRowsByChat[chatId]?[streamId]?["message"] as? [String: Any])?["metadata"]
        as? [String: Any])?["progressNodes"] as? [[String: Any]] ?? []
    var streamPayload: [String: Any] = [
      "streamId": streamId,
      "taskId": taskId,
      "status": "running",
      "text": displayText,
      "progressNodes": existingNodes,
      "userId": agentUserId as Any,
      "sequence": seq,
    ]
    if let reply = normalizedString(payload["replyToId"] ?? payload["reply_to_id"]) {
      streamPayload["sourceMessageId"] = reply
      streamPayload["replyToId"] = reply
    }
    applyAgentStreamLocked(chatId: chatId, payload: streamPayload)
  }

  private static func lightweightStreamText(from accumulated: String, provider: String) -> String {
    let p = provider.lowercased()
    var texts: [String] = []
    for rawLine in accumulated.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      guard line.contains("{"), line.contains("}") else {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, !t.hasPrefix("{"), t.count > 1 { texts.append(t) }
        continue
      }
      if let range = line.range(of: #""text"\s*:\s*""#, options: .regularExpression) {
        let after = line[range.upperBound...]
        if let end = after.firstIndex(of: "\"") {
          let chunk = String(after[..<end])
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
          if !chunk.isEmpty { texts.append(chunk) }
        }
      }
      if line.contains("\"type\":\"agent_message\"") || line.contains("\"type\": \"agent_message\"")
      {
        if let range = line.range(of: #""text"\s*:\s*""#, options: .regularExpression) {
          let after = line[range.upperBound...]
          if let end = after.firstIndex(of: "\"") {
            let chunk = String(after[..<end])
              .replacingOccurrences(of: "\\n", with: "\n")
            if !chunk.isEmpty { texts.append(chunk) }
          }
        }
      }
    }
    if p == "grok" || p == "agy" || p == "antigravity" {
      let joined = texts.joined()
      if !joined.isEmpty { return joined }
    }
    return texts.joined()
  }

  private func applyAgentStreamLocked(chatId: String, payload: [String: Any]) {
    guard let streamId = normalizedString(payload["streamId"] ?? payload["stream_id"]) else {
      return
    }
    let status = (normalizedString(payload["status"]) ?? "running").lowercased()
    let agentUserId = normalizedString(payload["userId"] ?? payload["user_id"] ?? payload["id"])
    let taskId = normalizedString(payload["taskId"] ?? payload["task_id"])
    let teamRunId = normalizedString(payload["teamRunId"] ?? payload["team_run_id"])
    let teamMode = (normalizedString(payload["teamMode"] ?? payload["team_mode"]) ?? "")
      .lowercased()
    let suppressVisible =
      (payload["suppressVisible"] as? Bool) == true
      || (payload["suppress_visible"] as? Bool) == true
      || (normalizedString(payload["teamRole"] ?? payload["team_role"]) ?? "").lowercased()
        == "worker"
    let isSupervisorTeam =
      teamMode == "supervisor" || teamMode == "group_supervisor"

    if suppressVisible, isSupervisorTeam, let teamRunId, !teamRunId.isEmpty {
      mergeSuppressedTeamWorkerStreamLocked(
        chatId: chatId,
        teamRunId: teamRunId,
        payload: payload
      )
      return
    }

    if streamId.hasPrefix("stream-"), let taskId, !taskId.isEmpty {
      cloudProgressAtMsByTask["\(chatId):\(taskId)"] = Int64(nowMs())
    }

    if let taskId, !taskId.isEmpty,
      let provider = normalizedString(payload["provider"])
        ?? bridgeProviderForAgentIdentifier(agentUserId)
        ?? bridgeProviderForChatLocked(chatId: chatId),
      let seq = parseLongValue(payload["sequence"]), seq > 0
    {
      let key = "\(provider):\(chatId):\(taskId)"
      let prev = lanProgressSeqByTask[key] ?? 0
      if Int(seq) < prev {
        return
      }
      if Int(seq) > prev {
        lanProgressSeqByTask[key] = Int(seq)
      }
    }

    var effectiveRowId = streamId
    var perTaskRowIds = liveStreamTaskRowIdByChatId[chatId] ?? [:]
    if isSupervisorTeam, let teamRunId, !teamRunId.isEmpty {
      let teamKey = "team:\(teamRunId)"
      if let existingRowId = perTaskRowIds[teamKey] {
        effectiveRowId = existingRowId
      } else {
        perTaskRowIds[teamKey] = streamId
        effectiveRowId = streamId
      }
    } else if let taskId, !taskId.isEmpty {
      if let existingRowId = perTaskRowIds[taskId] {
        effectiveRowId = existingRowId
      } else if isAgentTaskRetiredLocked(chatId: chatId, taskId: taskId),
        liveMessageRowsByChat[chatId]?[streamId] == nil
      {
        NSLog(
          "[ChatEngine][AgentStream] drop late frame chat=%@ task=%@ stream=%@ — turn already settled",
          String(chatId.suffix(12)), String(taskId.suffix(16)), String(streamId.prefix(24)))
        return
      } else {
        perTaskRowIds[taskId] = streamId
        effectiveRowId = streamId
      }
    }
    if !perTaskRowIds.isEmpty {
      liveStreamTaskRowIdByChatId[chatId] = perTaskRowIds
    }

    let frameSessionId = normalizedString(payload["sessionId"] ?? payload["session_id"])
    if let sessionId = frameSessionId,
      !sessionId.isEmpty,
      liveBridgeSessionIngestByChatId[chatId]?.sessionId != sessionId
    {
      let provider = bridgeProviderForChatLocked(chatId: chatId) ?? ""
      if !provider.isEmpty {
        liveBridgeSessionIngestByChatId[chatId] = (
          provider: provider, sessionId: sessionId, requestId: UUID().uuidString
        )
      }
    }

    var text = normalizedString(payload["text"]) ?? ""
    var progressNodes = (payload["progressNodes"] as? [[String: Any]]) ?? []
    if status != "done", status != "error", status != "stopped" {
      progressNodes = Self.collapseLiveTextProgressNodes(progressNodes)
    }
    if let existingMessage = liveMessageRowsByChat[chatId]?[effectiveRowId]?["message"] as? [String: Any] {
      let existingText = normalizedString(existingMessage["plainContent"]) ?? ""
      let existingProgressNodes =
        ((existingMessage["metadata"] as? [String: Any])?["progressNodes"] as? [[String: Any]]) ?? []
      let existingHasContent =
        !existingText.isEmpty
        || existingProgressNodes.contains { node in
          let kind = (normalizedString(node["kind"] ?? node["itemType"]) ?? "").lowercased()
          let label = normalizedString(node["label"]) ?? ""
          return kind == "text" || kind == "thinking" || kind == "compacting" || label.count > 2
        }
      let nextHasContent =
        !text.isEmpty
        || progressNodes.contains { node in
          let kind = (normalizedString(node["kind"] ?? node["itemType"]) ?? "").lowercased()
          let label = normalizedString(node["label"]) ?? ""
          return kind == "text" || kind == "thinking" || kind == "compacting" || label.count > 2
        }
      if progressNodes.count < existingProgressNodes.count, text.count <= existingText.count {
        text = existingText
        progressNodes = existingProgressNodes
        if status != "done", status != "error", status != "stopped" {
          progressNodes = Self.collapseLiveTextProgressNodes(progressNodes)
        }
      } else if existingHasContent, !nextHasContent {
        text = existingText.isEmpty ? text : existingText
        progressNodes = existingProgressNodes.isEmpty ? progressNodes : existingProgressNodes
      }
    }
    let progressKindOrder =
      progressNodes
      .map { node in (normalizedString(node["kind"] ?? node["itemType"]) ?? "step").lowercased() }
      .joined(separator: ",")
    let sourceMessageId = normalizedString(
      payload["sourceMessageId"] ?? payload["source_message_id"] ?? payload["replyToId"] ?? payload["reply_to_id"]
    )
    let sequence = parseLongValue(payload["sequence"])
    let bridgeSentAtMs = parseLongValue(payload["bridgeSentAtMs"] ?? payload["bridge_sent_at_ms"])
    let serverReceivedAtMs = parseLongValue(payload["serverReceivedAtMs"] ?? payload["server_received_at_ms"])
    let serverBroadcastAtMs = parseLongValue(payload["serverBroadcastAtMs"] ?? payload["server_broadcast_at_ms"])
    let phoneReceivedAtMs = Int64(nowMs())
    let shouldLogFrame =
      sequence == nil
      || (sequence ?? 0) <= 5
      || (sequence ?? 0) % 5 == 0
      || status == "done" || status == "error" || status == "stopped"
      || progressKindOrder.contains("compacting")
      || progressKindOrder.contains("thinking")
    if shouldLogFrame {
      let bridgeToServer = bridgeSentAtMs.flatMap { sent in serverReceivedAtMs.map { $0 - sent } }
      let serverToPhone = serverBroadcastAtMs.map { phoneReceivedAtMs - $0 }
      let endToEnd = bridgeSentAtMs.map { phoneReceivedAtMs - $0 }
      let mode = transportModeLocked()
      let wsConnected = (state["connected"] as? Bool) == true
      let transport =
        "mode=\(mode) phoenix=\(phoenixClient == nil ? "nil" : (wsConnected ? "ws-up" : "ws-down"))"
      NSLog(
        "[ChatEngine][AgentStream] chat=%@ stream=%@ row=%@ seq=%@ status=%@ text=%d nodes=%d order=[%@] transport=%@ bridgeToServer=%@ms serverToPhone=%@ms e2e=%@ms",
        chatId,
        streamId,
        effectiveRowId == streamId ? "-" : effectiveRowId,
        sequence.map(String.init) ?? "nil",
        status,
        text.count,
        progressNodes.count,
        progressKindOrder,
        transport,
        bridgeToServer.map(String.init) ?? "nil",
        serverToPhone.map(String.init) ?? "nil",
        endToEnd.map(String.init) ?? "nil"
      )
    }

    if status == "done" || status == "error" || status == "stopped" {
      clearAgentProgressLocked(chatId: chatId, status: status, reason: "streamFrame(status=\(status))")
      agentTurnRunningAtMsByChatId.removeValue(forKey: chatId)
      activeIsolatedRunIdByChatId.removeValue(forKey: chatId)
      if let doneSessionId = frameSessionId ?? liveBridgeSessionIngestByChatId[chatId]?.sessionId,
        !doneSessionId.isEmpty
      {
        bridgeMarkSessionSettledLocked(chatId: chatId, sessionId: doneSessionId, contentSig: "")
      }
      if let taskId, !taskId.isEmpty {
        removeBridgeTaskTrackingLocked(chatId: chatId, taskId: taskId)
      }
      if let agentUserId, !agentUserId.isEmpty,
        hasFinishedBridgeSessionRowLocked(chatId: chatId, agentUserId: agentUserId)
      {
        let removal = removeAgentStreamRowsLocked(chatId: chatId, agentUserId: agentUserId)
        postChangeLocked(
          reason: "chatRowsReloaded",
          userInfo: ["chatId": chatId, "state": statusSnapshotLocked()]
        )
        postChatDeltaLocked(
          chatId: chatId, inserted: [], updated: [], deleted: removal.removedIds,
          source: "streamSettle")
        return
      }
      let changed = settleLiveBridgeMessageLocked(
        chatId: chatId,
        messageId: effectiveRowId,
        terminalStatus: status
      )
      postChangeLocked(
        reason: "chatMessageChanged",
        userInfo: ["chatId": chatId, "messageId": effectiveRowId, "state": statusSnapshotLocked()]
      )
      if changed {
        postChatDeltaLocked(
          chatId: chatId, inserted: [], updated: [effectiveRowId], deleted: [],
          source: "streamSettle")
      }
      return
    }

    let streamProgressLabel = agentProgressLabelFromNodes(progressNodes) ?? "Thinking"
    setAgentProgressLocked(
      chatId: chatId,
      label: streamProgressLabel,
      tool: nil,
      status: "running"
    )
    agentTurnRunningAtMsByChatId[chatId] = Int64(nowMs())
    if normalizedString(payload["runtime"]) == "isolated" {
      activeIsolatedRunIdByChatId[chatId] = normalizedString(payload["runId"] ?? payload["run_id"]) ?? streamId
    }
    if let liveSessionId = frameSessionId, !liveSessionId.isEmpty {
      bridgeClearSessionSettledLocked(chatId: chatId, sessionId: liveSessionId)
    }

    let hasRenderableStreamContent =
      !text.isEmpty
      || progressNodes.contains { node in
        let kind = (normalizedString(node["kind"] ?? node["itemType"]) ?? "").lowercased()
        let label = (normalizedString(node["label"] ?? node["title"]) ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let detail = (
          normalizedString(node["detail"] ?? node["messageContent"] ?? node["messagePreview"]) ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlaceholderThinking =
          (kind == "thinking" || label == "thinking" || label == "thinking...") && detail.isEmpty
        return !isPlaceholderThinking
      }
    var perChat = agentStreamTimestampsByChat[chatId] ?? [:]
    let timestampMs: Int64
    if let stamped = perChat[effectiveRowId] {
      timestampMs = stamped
    } else if hasRenderableStreamContent {
      timestampMs = Int64(nowMs())
      perChat[effectiveRowId] = timestampMs
      agentStreamTimestampsByChat[chatId] = perChat
    } else {
      timestampMs = Int64(nowMs())
    }

    var metadata: [String: Any] = [
      "progressNodes": progressNodes,
      "agentWorkerVia": "bridge",
      "isStreaming": true,
    ]
    if let sourceMessageId {
      metadata["sourceMessageId"] = sourceMessageId
      metadata["actionSourceId"] = sourceMessageId
    }
    if let taskId {
      metadata["agentTaskId"] = taskId
    }
    if let repoName = normalizedString(payload["repoName"] ?? payload["repo_name"]) {
      metadata["agentRuntimeRepoName"] = repoName
    }
    if let cwd = normalizedString(payload["cwd"]) {
      metadata["agentRuntimeCwd"] = cwd
    }
    if let workMode = normalizedString(payload["workMode"] ?? payload["work_mode"]) {
      metadata["agentRuntimeWorkMode"] = workMode
    }
    if let model = normalizedString(payload["model"]) {
      metadata["agentRuntimeModel"] = model
    }
    if let advisor = normalizedString(payload["advisor"] ?? payload["advisorModel"] ?? payload["advisor_model"]) {
      metadata["agentRuntimeAdvisor"] = advisor
    }
    let existingRuntime: [String: Any] = {
      guard let existingRow = liveMessageRowsByChat[chatId]?[effectiveRowId],
        let existingMessage = existingRow["message"] as? [String: Any],
        let existingMeta = existingMessage["metadata"] as? [String: Any]
      else { return [:] }
      return (existingMeta["agentRuntime"] as? [String: Any]) ?? [:]
    }()
    var liveRuntime: [String: Any] = [
      "status": "running",
    ]
    if let taskId { liveRuntime["taskId"] = taskId }
    if let provider = bridgeProviderForChatLocked(chatId: chatId) {
      liveRuntime["provider"] = provider
    }
    for (wireKey, snakeKey, runtimeKey) in [
      ("repoName", "repo_name", "repoName"), ("cwd", "cwd", "cwd"),
      ("workMode", "work_mode", "workMode"), ("model", "model", "model"),
      ("advisor", "advisor_model", "advisor"), ("teamMode", "team_mode", "teamMode"),
      ("teamRunId", "team_run_id", "teamRunId"),
      ("teamWorker", "team_worker", "teamWorker"),
      ("computerId", "computer_id", "computerId"),
      ("computerLabel", "computer_label", "computerLabel"),
    ] {
      if let value = normalizedString(payload[wireKey] ?? payload[snakeKey]) {
        liveRuntime[runtimeKey] = value
      }
    }
    if let workers = payload["teamWorkers"] as? [String], !workers.isEmpty {
      liveRuntime["teamWorkers"] = workers
    }
    if let lead = normalizedString(payload["leadWorker"] ?? payload["lead_worker"]) {
      liveRuntime["leadWorker"] = lead
    }
    if let role = normalizedString(payload["teamRole"] ?? payload["team_role"]) {
      liveRuntime["teamRole"] = role
    }
    var statusList = payload["teamWorkersStatus"] as? [[String: Any]]
    if (statusList == nil || statusList?.isEmpty == true),
      let teamRunId,
      let stashed = pendingTeamWorkersStatusByChatId[chatId]?[teamRunId],
      !stashed.isEmpty
    {
      statusList = stashed
      pendingTeamWorkersStatusByChatId[chatId]?.removeValue(forKey: teamRunId)
      if pendingTeamWorkersStatusByChatId[chatId]?.isEmpty == true {
        pendingTeamWorkersStatusByChatId.removeValue(forKey: chatId)
      }
    }
    if let statusList, !statusList.isEmpty {
      liveRuntime["teamWorkersStatus"] = statusList
      metadata["teamWorkersStatus"] = statusList
    }
    for key in ["teamMode", "teamRunId", "teamWorker", "teamWorkers", "leadWorker", "teamRole"] {
      if liveRuntime[key] == nil, let carried = existingRuntime[key] {
        liveRuntime[key] = carried
      }
    }
    if (liveRuntime["teamWorkersStatus"] as? [[String: Any]])?.isEmpty != false,
      let carriedStatus = existingRuntime["teamWorkersStatus"] as? [[String: Any]],
      !carriedStatus.isEmpty
    {
      liveRuntime["teamWorkersStatus"] = carriedStatus
      metadata["teamWorkersStatus"] = carriedStatus
    }
    liveRuntime["controls"] = ["canCancel": true, "canRevert": false]
    metadata["agentRuntime"] = liveRuntime
    if let sequence {
      metadata["agentStreamSequence"] = sequence
    }
    if let bridgeSentAtMs {
      metadata["agentBridgeSentAtMs"] = bridgeSentAtMs
    }
    if let serverReceivedAtMs {
      metadata["agentServerReceivedAtMs"] = serverReceivedAtMs
    }
    if let serverBroadcastAtMs {
      metadata["agentServerBroadcastAtMs"] = serverBroadcastAtMs
    }

    let hadExistingStreamRow = liveMessageRowsByChat[chatId]?[effectiveRowId] != nil
    let streamProvider =
      agentUserId.flatMap { Self.bridgeAgentProvidersByUserId[$0.lowercased()] }
      ?? bridgeProviderForAgentIdentifier(agentUserId)
      ?? bridgeProviderForChatLocked(chatId: chatId)
    let streamAgentName: String? = {
      guard let streamProvider else { return nil }
      switch streamProvider {
      case "claude": return "Claude"
      case "codex": return "Codex"
      case "grok": return "Grok"
      case "agy", "antigravity": return "Agy"
      default: return streamProvider.capitalized
      }
    }()
    if let streamAgentName {
      metadata["agentName"] = streamAgentName
      metadata["agentUsername"] = streamProvider
    }
    if let agentUserId {
      metadata["agentUserId"] = agentUserId
    }
    var synthetic: [String: Any] = [
      "id": effectiveRowId,
      "type": "text",
      "timestamp": timestampMs,
      "isAgentMessage": true,
      "plainContent": text,
      "metadata": metadata,
    ]
    if let sourceMessageId {
      synthetic["replyToId"] = sourceMessageId
    }
    if let agentUserId {
      synthetic["fromId"] = agentUserId
      synthetic["agentUserId"] = agentUserId
    }
    if let streamAgentName {
      synthetic["agentName"] = streamAgentName
      if let streamProvider {
        synthetic["agentUsername"] = streamProvider
      }
    }

    _ = applyNativeIncomingMessageEventLocked(
      chatId: chatId, payload: synthetic, postDelta: false)
    mutateLiveMessagePayloadLocked(chatId: chatId, messageId: effectiveRowId) { message in
      message["isStreaming"] = true
    }
    let removedBridgeIds = removeRunningBridgeSessionRowsLocked(
      chatId: chatId, agentUserId: agentUserId)
    postChangeLocked(
      reason: hadExistingStreamRow ? "chatMessageChanged" : "chatMessageInserted",
      userInfo: ["chatId": chatId, "messageId": effectiveRowId, "state": statusSnapshotLocked()]
    )
    postChatDeltaLocked(
      chatId: chatId,
      inserted: hadExistingStreamRow ? [] : [effectiveRowId],
      updated: hadExistingStreamRow ? [effectiveRowId] : [],
      deleted: removedBridgeIds,
      source: "stream")
  }

  private func mergeSuppressedTeamWorkerStreamLocked(
    chatId: String,
    teamRunId: String,
    payload: [String: Any]
  ) {
    let teamKey = "team:\(teamRunId)"
    let rowId = liveStreamTaskRowIdByChatId[chatId]?[teamKey]
    let statusList =
      (payload["teamWorkersStatus"] as? [[String: Any]])
      ?? (payload["team_workers_status"] as? [[String: Any]])
      ?? []

    if let worker = normalizedString(payload["teamWorker"] ?? payload["team_worker"]),
      let lastLabel = normalizedString(payload["lastLabel"] ?? payload["last_label"])
        ?? normalizedString(payload["status"])
    {
      let label = "\(worker.capitalized) · \(lastLabel)"
      setAgentProgressLocked(chatId: chatId, label: label, tool: nil, status: "running")
    }

    guard let rowId else {
      var stash = pendingTeamWorkersStatusByChatId[chatId] ?? [:]
      if !statusList.isEmpty {
        stash[teamRunId] = statusList
        pendingTeamWorkersStatusByChatId[chatId] = stash
      }
      return
    }

    let changed = mutateLiveMessagePayloadLocked(chatId: chatId, messageId: rowId) { message in
      var metadata = (message["metadata"] as? [String: Any]) ?? [:]
      if !statusList.isEmpty {
        metadata["teamWorkersStatus"] = statusList
        var runtime = (metadata["agentRuntime"] as? [String: Any]) ?? [:]
        runtime["teamWorkersStatus"] = statusList
        runtime["teamRunId"] = teamRunId
        runtime["teamMode"] = normalizedString(payload["teamMode"] ?? payload["team_mode"])
          ?? runtime["teamMode"] as? String ?? "supervisor"
        metadata["agentRuntime"] = runtime
      }
      if let worker = normalizedString(payload["teamWorker"] ?? payload["team_worker"]),
        let nodes = payload["progressNodes"] as? [[String: Any]], !nodes.isEmpty
      {
        var byWorker = (metadata["teamWorkerProgressNodes"] as? [String: Any]) ?? [:]
        byWorker[worker] = nodes
        metadata["teamWorkerProgressNodes"] = byWorker
        var chatCache = teamWorkerProgressNodesByChatId[chatId] ?? [:]
        var runCache = chatCache[teamRunId] ?? [:]
        runCache[worker] = nodes
        chatCache[teamRunId] = runCache
        teamWorkerProgressNodesByChatId[chatId] = chatCache
      }
      message["metadata"] = metadata
    }
    if changed {
      postChatDeltaLocked(
        chatId: chatId, inserted: [], updated: [rowId], deleted: [], source: "stream")
    }

    postChangeLocked(
      reason: "chatMessageChanged",
      userInfo: ["chatId": chatId, "messageId": rowId, "state": statusSnapshotLocked()]
    )
  }

  private static func collapseLiveTextProgressNodes(_ nodes: [[String: Any]]) -> [[String: Any]] {
    func kindOf(_ node: [String: Any]) -> String {
      let raw = (node["kind"] as? String) ?? (node["itemType"] as? String) ?? ""
      return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    guard nodes.count > 1 else { return nodes }
    var out: [[String: Any]] = []
    for node in nodes {
      let kind = kindOf(node)
      if kind == "text", let last = out.last, kindOf(last) == "text" {
        let label = (node["label"] as? String) ?? ""
        let prev = (last["label"] as? String) ?? ""
        if label.count >= prev.count {
          out[out.count - 1] = node
        }
        continue
      }
      out.append(node)
    }
    return out
  }

  private func agentProgressLabelFromNodes(_ progressNodes: [[String: Any]]) -> String? {
    if let compacting = progressNodes.reversed().first(where: { node in
      let kind = (normalizedString(node["kind"] ?? node["itemType"]) ?? "").lowercased()
      let status = (normalizedString(node["status"]) ?? "").lowercased()
      return kind == "compacting" && ["running", "streaming", "in_progress", "active"].contains(status)
    }) {
      return normalizedString(compacting["label"] ?? compacting["title"]) ?? "Compacting conversation…"
    }
    let latestActionNode = progressNodes.reversed().first(where: { node in
      ((normalizedString(node["kind"] ?? node["itemType"]) ?? "").lowercased()) != "text"
    })
    var label = latestActionNode.flatMap { normalizedString($0["label"] ?? $0["title"]) }
    if let node = latestActionNode {
      let kind = (normalizedString(node["kind"] ?? node["itemType"]) ?? "").lowercased()
      if kind == "thinking",
        let tokens = parseLongValue(node["tokens"]), tokens > 0
      {
        let count =
          tokens >= 1000
          ? String(format: "%.1fk tokens", Double(tokens) / 1000.0)
          : "\(tokens) tokens"
        label = "Thinking · \(count)"
      } else if kind == "compacting" {
        label = normalizedString(node["label"] ?? node["title"]) ?? "Compacting conversation…"
      }
    }
    return label
      ?? progressNodes.reversed().compactMap { node in
        normalizedString(node["label"] ?? node["title"])
      }.first
  }

  private func hasFinishedBridgeSessionRowLocked(chatId: String, agentUserId: String? = nil) -> Bool {
    guard let perChat = liveMessageRowsByChat[chatId] else { return false }
    let targetAgent = normalizedUpper(agentUserId)
    return perChat.contains { key, value in
      guard key.hasPrefix("bridge-") else { return false }
      guard let message = value["message"] as? [String: Any] else { return false }
      guard (message["isAgentMessage"] as? Bool) == true else { return false }
      if let targetAgent {
        let rowAgent = normalizedUpper(message["agentUserId"] ?? message["fromId"])
        guard let rowAgent, rowAgent == targetAgent else { return false }
      }
      let meta = message["metadata"] as? [String: Any]
      let streaming =
        (message["isStreaming"] as? Bool) == true || (meta?["isStreaming"] as? Bool) == true
      return !streaming
    }
  }

  @discardableResult
  private func removeAgentStreamRowsLocked(
    chatId: String, agentUserId: String?
  ) -> (slotTs: Int64?, removedIds: [String]) {
    guard var perChat = liveMessageRowsByChat[chatId], !perChat.isEmpty else {
      return (nil, [])
    }
    let targetAgent = normalizedUpper(agentUserId)
    let streamIds = perChat.keys.filter {
      $0.hasPrefix("stream-") || $0.hasPrefix("lan-")
    }
    guard !streamIds.isEmpty else { return (nil, []) }
    var removedIds = Set<String>()
    var inheritedSlotTs: Int64?
    for streamId in streamIds {
      if let targetAgent {
        let rowAgent = normalizedUpper(
          (perChat[streamId]?["message"] as? [String: Any])?["agentUserId"]
            ?? (perChat[streamId]?["message"] as? [String: Any])?["fromId"])
        if let rowAgent, rowAgent != targetAgent { continue }
      }
      if let stamped = agentStreamTimestampsByChat[chatId]?[streamId] {
        inheritedSlotTs = min(inheritedSlotTs ?? stamped, stamped)
      }
      perChat.removeValue(forKey: streamId)
      removedIds.insert(streamId)
    }
    guard !removedIds.isEmpty else { return (nil, []) }
    VibeDebugLog.log(
      "[EmptyTrace] removeAgentStreamRows chatId=%@ removed=%d liveLeft=%d",
      String(chatId.suffix(12)), removedIds.count, perChat.isEmpty ? 0 : perChat.count)
    if perChat.isEmpty {
      liveMessageRowsByChat.removeValue(forKey: chatId)
    } else {
      liveMessageRowsByChat[chatId] = perChat
    }
    if var perChatTimestamps = agentStreamTimestampsByChat[chatId] {
      for id in removedIds { perChatTimestamps.removeValue(forKey: id) }
      if perChatTimestamps.isEmpty {
        agentStreamTimestampsByChat.removeValue(forKey: chatId)
      } else {
        agentStreamTimestampsByChat[chatId] = perChatTimestamps
      }
    }
    if var perChatTaskRowIds = liveStreamTaskRowIdByChatId[chatId] {
      for (taskId, rowId) in perChatTaskRowIds where removedIds.contains(rowId) {
        markAgentTaskRetiredLocked(chatId: chatId, taskId: taskId)
      }
      for rowId in removedIds where rowId.hasPrefix("lan-") {
        markAgentTaskRetiredLocked(chatId: chatId, taskId: String(rowId.dropFirst(4)))
      }
      perChatTaskRowIds = perChatTaskRowIds.filter { !removedIds.contains($0.value) }
      if perChatTaskRowIds.isEmpty {
        liveStreamTaskRowIdByChatId.removeValue(forKey: chatId)
      } else {
        liveStreamTaskRowIdByChatId[chatId] = perChatTaskRowIds
      }
    }
    return (inheritedSlotTs, removedIds.sorted())
  }

  private func removeRunningBridgeSessionRowsLocked(
    chatId: String, agentUserId: String? = nil
  ) -> [String] {
    guard var perChat = liveMessageRowsByChat[chatId], !perChat.isEmpty else { return [] }
    let targetAgent = normalizedUpper(agentUserId)
    var removed: [String] = []
    for (key, entry) in perChat where key.hasPrefix("bridge-") {
      let message = entry["message"] as? [String: Any]
      let metaStreaming = (message?["metadata"] as? [String: Any])?["isStreaming"] as? Bool
      let topStreaming = message?["isStreaming"] as? Bool
      guard metaStreaming == true || topStreaming == true else { continue }
      if let targetAgent {
        let rowAgent = normalizedUpper(message?["agentUserId"] ?? message?["fromId"])
        if let rowAgent, rowAgent != targetAgent { continue }
      }
      removed.append(key)
    }
    guard !removed.isEmpty else { return [] }
    for key in removed { perChat.removeValue(forKey: key) }
    if perChat.isEmpty {
      liveMessageRowsByChat.removeValue(forKey: chatId)
    } else {
      liveMessageRowsByChat[chatId] = perChat
    }
    return removed.sorted()
  }

  private func emitAgentProgressChangeLocked(
    chatId: String,
    state: AgentProgressState?,
    previous: AgentProgressState? = nil,
    status: String? = nil
  ) {
    let snapshot = statusSnapshotLocked()
    var userInfo: [String: Any] = [
      "chatId": chatId,
      "state": snapshot,
      "isActive": state != nil,
    ]
    if let state {
      userInfo["label"] = state.label
      userInfo["status"] = state.status
      userInfo["updatedAtMs"] = state.updatedAtMs
      if let tool = state.tool {
        userInfo["tool"] = tool
      }
    } else {
      userInfo["status"] = status ?? previous?.status ?? "done"
      if let previous {
        userInfo["updatedAtMs"] = previous.updatedAtMs
      }
    }
    postChangeLocked(reason: "agentProgress", userInfo: userInfo)
  }

  private func statusSnapshotLocked() -> [String: Any] {
    var snapshot = state
    snapshot["transportMode"] = transportModeLocked()
    snapshot["activeBridgeId"] = normalizedString(getConfigValueLocked("activeBridgeId"))
    snapshot["activePacketBridgeId"] = normalizedString(getConfigValueLocked("activePacketBridgeId"))
    snapshot["bridgeBaseUrl"] = bridgeBaseURLLocked()?.absoluteString
    snapshot["packetProxyPort"] = packetProxyPortLocked()
    snapshot["packetStatus"] = normalizedString(getConfigValueLocked("packetStatus")) ?? state["state"]
    snapshot["packetLastError"] = state["lastError"]
    snapshot["bridgeReachable"] =
      transportModeLocked() == "bridge_text" ? ((state["connected"] as? Bool) == true) : false
    snapshot["disableCalls"] = disableCallsLocked()
    snapshot["disableMedia"] = disableMediaLocked()
    snapshot["disableRemoteAvatars"] = disableRemoteAvatarsLocked()
    snapshot["onlineUserCount"] = onlineUsers.count
    snapshot["onlineUserIds"] = Array(onlineUsers).sorted()
    snapshot["lastSeenUserCount"] = lastSeenByUserId.count
    snapshot["boundSurfaceCount"] = surfaceBindings.count
    snapshot["boundChatCount"] = Set(surfaceBindings.values.compactMap(\.chatId)).count
    snapshot["openChatChannelCount"] = openChatChannels.count
    snapshot["openChatChannels"] = openChatChannels
    snapshot["receiptCount"] = receiptIndex.values.reduce(0) { $0 + $1.count }
    snapshot["localStatusCount"] = localStatusIndex.values.reduce(0) { $0 + $1.count }
    snapshot["nativeJoinedChatCount"] = nativeJoinedChatIds.count
    snapshot["outboundDraftCount"] = pendingOutboundDraftsByMessageId.count
    snapshot["outboundQueuedCount"] = pendingOutboundQueueByChat.values.reduce(0) { $0 + $1.count }
    snapshot["typingChatCount"] = peerTypingUserIdsByChatId.count
    snapshot["typingUserCount"] = peerTypingUserIdsByChatId.values.reduce(0) { $0 + $1.count }
    snapshot["agentProgressChatCount"] = agentProgressByChatId.count
    snapshot["pinnedChatCount"] = pinnedMessagesByChatId.count
    snapshot["pinnedMessageCount"] = pinnedMessagesByChatId.values.reduce(0) { $0 + $1.count }
    snapshot["journalCount"] = journalEntryCount
    return snapshot
  }

  @available(iOS 13.0, *)
  private func connectNativePresence() -> [String: Any] {
    _ = syncOnQueue {
      bootstrapConfigFromNativeSessionIfNeededLocked(trigger: "connect_native_presence")
    }
    let config = store.getConfig()
    let transportMode = transportModeLocked(config: config)
    let socketUrlString = normalizedString(config["socketUrl"]) ?? normalizedString(config["url"])
    let socketURL = socketUrlString.flatMap(URL.init(string:))
    let bridgeBaseURL = bridgeBaseURLLocked(config: config)
    let authToken = normalizedString(config["authToken"]) ?? normalizedString(config["token"])
    let userId = normalizedString(config["userId"])
    let userTopic =
      normalizedString(config["userChannelTopic"])
      ?? (userId != nil ? "user:\(userId!)" : nil)

    if transportMode == "offline" {
      return syncOnQueue {
        state["state"] = "offline"
        state["connected"] = false
        state["updatedAt"] = nowMs()
        state["note"] = "ChatEngine realtime transport disabled"
        state["transportMode"] = transportMode
        state["presenceSource"] = "shadow"
        appendJournalLocked(
          event: "connect-native-offline",
          payload: [
            "hasUserTopic": userTopic != nil,
          ])
        let snapshot = statusSnapshotLocked()
        postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
        return snapshot
      }
    }

    let resolvedTarget =
      transportMode == "bridge_text" ? bridgeBaseURL?.absoluteString : socketUrlString
    let packetProxyPort = packetProxyPortLocked(config: config)
    let proxyEnabled = packetProxyEnabledLocked(config: config)
    let hasRequiredPacketProxy = !proxyEnabled || packetProxyPort != nil
    if proxyEnabled, resolvedTarget != nil, userTopic != nil, packetProxyPort == nil {
      _ = ensurePacketRuntimeAsync(trigger: "connect_missing_packet_proxy")
      return getStatus()
    }
    guard resolvedTarget != nil, let userTopic, hasRequiredPacketProxy else {
      return syncOnQueue {
        state["state"] = "native-config-missing"
        state["connected"] = false
        state["updatedAt"] = nowMs()
        state["transportMode"] = transportMode
        state["note"] =
          transportMode == "bridge_text"
          ? "ChatEngine blackout bridge missing bridgeBaseUrl/userTopic config"
          : proxyEnabled
            ? "ChatEngine proxy missing socketUrl/userTopic/packetProxyPort config"
            : "ChatEngine native presence missing socketUrl/userTopic config"
        appendJournalLocked(
          event: "connect-native-missing-config",
          payload: [
            "hasSocketUrl": socketUrlString != nil,
            "hasBridgeBaseUrl": bridgeBaseURL != nil,
            "hasPacketProxyPort": packetProxyPort != nil,
            "hasUserTopic": userTopic != nil,
            "hasAuthToken": authToken != nil,
            "transportMode": transportMode,
          ])
        let snapshot = statusSnapshotLocked()
        postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
        return snapshot
      }
    }

    let signature =
      "\(transportMode)|\(resolvedTarget ?? "")|\(authToken ?? "")|\(userTopic)|\(packetProxyPort ?? 0)"
    let callbacks = ChatTransportCallbacks(
      onOpen: { [weak self] in self?.handleNativeSocketOpened(userTopic: userTopic) },
      onClose: { [weak self] code, reason in
        self?.handleNativeSocketClosed(code: code, reason: reason)
      },
      onError: { [weak self] error in self?.handleNativeSocketError(error) },
      onEvent: { [weak self] frame in self?.handleNativeSocketFrame(frame) }
    )

    let clientToReplace: ChatRealtimeTransport? = syncOnQueue {
      autoReconnectEnabled = true
      cancelReconnectLocked()
      var clientToReplace: ChatRealtimeTransport?
      if let existing = phoenixClient, nativeSocketSignature != signature {
        clientToReplace = existing
        phoenixClient = nil
        nativePresenceActive = false
        nativeUserJoinRef = nil
        nativeUserTopic = nil
        nativeChatJoinRefsByRef.removeAll()
        nativeJoinedChatIds.removeAll()
        nativePendingMessagePushRefs.removeAll()
        nativePendingEditPushRefs.removeAll()
        nativePendingDeletePushRefs.removeAll()
        nativePendingCallPushRefs.removeAll()
        pendingOutboundDraftsByMessageId.removeAll()
        pendingOutboundQueueByChat.removeAll()
        nativeTypingStateByChatId.removeAll()
        peerTypingUserIdsByChatId.removeAll()
        agentProgressByChatId.removeAll()
        nativeRecordingStateByChatId.removeAll()
        pinnedMessagesByChatId.removeAll()
        pinnedFetchInFlightChatIds.removeAll()
        historyLoadingChats.removeAll()
        clearSocketResetLiveRowsLocked()
      }
      if phoenixClient == nil {
        if transportMode == "bridge_text", let bridgeBaseURL {
          let client = ChatBlackoutTransport(
            baseURL: bridgeBaseURL,
            authToken: authToken,
            userId: userId ?? userTopic.replacingOccurrences(of: "user:", with: ""),
            activeBridgeId: normalizedString(config["activeBridgeId"]),
            bridgeBundle: config["bridgeBundle"] as? [String: Any],
            callbacks: callbacks
          )
          phoenixClient = client
        } else if let socketURL {
          let client = ChatPhoenixClient(
            baseURL: socketURL,
            params: [:],
            authToken: authToken,
            callbacks: callbacks
          )
          phoenixClient = client
        }
        nativeSocketSignature = signature
      }
      nativeUserTopic = userTopic
      state["connected"] = false
      state["state"] = "connecting-native-presence"
      state["updatedAt"] = nowMs()
      state["transportMode"] = transportMode
      state["activeBridgeId"] = normalizedString(config["activeBridgeId"])
      state["activePacketBridgeId"] = normalizedString(config["activePacketBridgeId"])
      state["bridgeBaseUrl"] = bridgeBaseURL?.absoluteString
      state["packetProxyPort"] = packetProxyPort
      state["note"] =
        transportMode == "bridge_text"
        ? "ChatEngine blackout bridge connecting"
        : proxyEnabled
          ? "ChatEngine connecting through proxy"
          : "ChatEngine native Phoenix presence connecting"
      state["presenceSource"] = nativePresenceActive ? "native" : "shadow"
      var connectPayload: [String: Any] = [
        "topic": userTopic,
        "transportMode": transportMode,
      ]
      if let bridgeBaseURL {
        connectPayload["bridgeBaseUrl"] = bridgeBaseURL.absoluteString
      }
      if let packetProxyPort {
        connectPayload["packetProxyPort"] = packetProxyPort
      }
      appendJournalLocked(event: "connect-native", payload: connectPayload)
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
      return clientToReplace
    }

    clientToReplace?.disconnect()
    (syncOnQueue { phoenixClient })?.connect()
    return getStatus()
  }

  private func handleNativeSocketOpened(userTopic: String) {
    queue.async {
      guard let client = self.phoenixClient else { return }
      self.cancelReconnectLocked()
      self.reconnectAttempt = 0
      self.state["connected"] = true
      self.state["state"] = "native-socket-open"
      self.state["updatedAt"] = self.nowMs()
      self.state["note"] = "ChatEngine native Phoenix socket open"
      NSLog("[ChatEngine] native Phoenix socket open - Triggering reconnects")
      self.appendJournalLocked(event: "native-socket-open", payload: [:])
      self.nativeUserTopic = userTopic
      self.nativeUserJoinRef = client.join(topic: userTopic, payload: [:])
      self.nativeChatJoinRefsByRef.removeAll()
      self.nativeJoinedChatIds.removeAll()
      self.nativePendingMessagePushRefs.removeAll()
      self.nativePendingEditPushRefs.removeAll()
      self.nativePendingDeletePushRefs.removeAll()
      self.nativePendingCallPushRefs.removeAll()
      self.nativeTypingStateByChatId.removeAll()
      self.peerTypingUserIdsByChatId.removeAll()
      self.agentProgressByChatId.removeAll()
      self.nativeRecordingStateByChatId.removeAll()
      self.pinnedMessagesByChatId.removeAll()
      self.pinnedFetchInFlightChatIds.removeAll()
      self.historyLoadingChats.removeAll()
      self.clearSocketResetLiveRowsLocked()
      for chatId in self.openChatChannels.keys {
        self.joinNativeChatTopicIfNeededLocked(chatId: chatId)
      }
      self.expireStaleQueuedOutboundLocked(trigger: "socket_open")
      self.ensureMlsProvisionedLocked(trigger: "socket_open")
      self.sweepOrphanedPendingLocked(trigger: "socket_open")
      let queuedChats = Array(self.pendingOutboundQueueByChat.keys)
      for chatId in queuedChats {
        self.scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "socket_open")
      }
      let snapshot = self.statusSnapshotLocked()
      self.postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
    }
  }

  private func handleNativeSocketClosed(code: Int, reason: String?) {
    queue.async {
      let inFlightMessages = Array(self.nativePendingMessagePushRefs.values)
      for pending in inFlightMessages {
        self.upsertLocalStatusLocked(
          chatId: pending.chatId, messageId: pending.messageId, status: "pending",
          allowDowngrade: true)
        if let draft = self.pendingOutboundDraftsByMessageId[pending.messageId] {
          self.queueOutboundDraftLocked(
            chatId: pending.chatId, messageId: pending.messageId, payload: draft,
            reason: "socket_closed")
        }
      }
      self.nativePresenceActive = false
      self.nativeUserJoinRef = nil
      self.nativeChatJoinRefsByRef.removeAll()
      self.nativeJoinedChatIds.removeAll()
      self.nativePendingMessagePushRefs.removeAll()
      self.nativePendingEditPushRefs.removeAll()
      self.nativePendingDeletePushRefs.removeAll()
      self.nativePendingCallPushRefs.removeAll()
      self.nativeTypingStateByChatId.removeAll()
      self.peerTypingUserIdsByChatId.removeAll()
      self.agentProgressByChatId.removeAll()
      self.nativeRecordingStateByChatId.removeAll()
      self.pinnedMessagesByChatId.removeAll()
      self.pinnedFetchInFlightChatIds.removeAll()
      self.historyLoadingChats.removeAll()
      self.clearSocketResetLiveRowsLocked()
      self.state["connected"] = false
      self.state["state"] = "native-socket-closed"
      self.state["updatedAt"] = self.nowMs()
      self.state["presenceSource"] = "shadow"
      self.appendJournalLocked(
        event: "native-socket-closed",
        payload: ["code": code, "reason": reason as Any]
      )
      self.scheduleReconnectLocked(reason: "socket_closed")
      let snapshot = self.statusSnapshotLocked()
      self.postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
    }
  }

  private func handleNativeSocketError(_ error: String) {
    queue.async {
      let normalizedError = error.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let shouldForceReconnect =
        normalizedError.contains("send_failed")
        || normalizedError.contains("receive_failed")
        || normalizedError.contains("network")
        || normalizedError.contains("timed out")
        || normalizedError.contains("heartbeat")
        || normalizedError.contains("connection")
      if shouldForceReconnect {
        let inFlightMessages = Array(self.nativePendingMessagePushRefs.values)
        for pending in inFlightMessages {
          self.upsertLocalStatusLocked(
            chatId: pending.chatId, messageId: pending.messageId, status: "pending",
            allowDowngrade: true)
          if let draft = self.pendingOutboundDraftsByMessageId[pending.messageId] {
            self.queueOutboundDraftLocked(
              chatId: pending.chatId, messageId: pending.messageId, payload: draft,
              reason: "socket_error")
          }
        }
        self.nativePresenceActive = false
        self.nativeUserJoinRef = nil
        self.nativeChatJoinRefsByRef.removeAll()
        self.nativeJoinedChatIds.removeAll()
        self.nativePendingMessagePushRefs.removeAll()
        self.nativePendingEditPushRefs.removeAll()
        self.nativePendingDeletePushRefs.removeAll()
        self.nativePendingCallPushRefs.removeAll()
        self.nativeTypingStateByChatId.removeAll()
        self.peerTypingUserIdsByChatId.removeAll()
        self.agentProgressByChatId.removeAll()
        self.nativeRecordingStateByChatId.removeAll()
        self.pinnedMessagesByChatId.removeAll()
        self.pinnedFetchInFlightChatIds.removeAll()
        self.state["connected"] = false
        self.state["state"] = "native-socket-error"
        self.state["presenceSource"] = "shadow"
      }
      self.state["updatedAt"] = self.nowMs()
      self.state["lastNativeSocketError"] = error
      self.appendJournalLocked(event: "native-socket-error", payload: ["error": error])
      if shouldForceReconnect {
        self.scheduleReconnectLocked(reason: "socket_error")
      }
      let snapshot = self.statusSnapshotLocked()
      self.postChangeLocked(reason: "engineError", userInfo: ["state": snapshot, "error": error])
    }
  }

  @available(iOS 13.0, *)
  private func expirePendingCallSignalsLocked(now: Int) {
    let before = nativePendingCallSignals.count
    nativePendingCallSignals.removeAll { signal in
      now - signal.createdAtMs > nativeCallSignalMaxAgeMs
    }
    let expired = before - nativePendingCallSignals.count
    if expired > 0 {
      appendJournalLocked(event: "native-call-signal-expired", payload: ["count": expired])
    }
  }

  @available(iOS 13.0, *)
  private func flushPendingCallSignalsLocked(trigger: String) {
    guard let client = phoenixClient,
      let topic = nativeUserTopic,
      (state["connected"] as? Bool) == true,
      nativePresenceActive
    else { return }

    let now = nowMs()
    expirePendingCallSignalsLocked(now: now)
    guard !nativePendingCallSignals.isEmpty else { return }

    let signals = nativePendingCallSignals
    nativePendingCallSignals.removeAll()
    for signal in signals {
      let ref = client.push(topic: topic, event: signal.event, payload: signal.payload)
      nativePendingCallPushRefs[ref] = signal.id
      appendJournalLocked(
        event: "native-call-signal-flush",
        payload: ["id": signal.id, "event": signal.event, "ref": ref, "topic": topic, "trigger": trigger]
      )
    }
    state["updatedAt"] = now
    let snapshot = statusSnapshotLocked()
    postChangeLocked(
      reason: "callSignalSent",
      userInfo: ["count": signals.count, "trigger": trigger, "state": snapshot]
    )
  }

  private func handleUserCallEventLocked(event: String, payload: [String: Any]) -> Bool {
    guard ["call-start", "call-accepted", "call-end", "webrtc-signal"].contains(event) else {
      return false
    }

    var callPayload = makeJSONSafeMap(payload)
    callPayload["event"] = event
    callPayload["direction"] = "inbound"
    appendJournalLocked(
      event: "native-call-signal-inbound",
      payload: [
        "event": event,
        "callId": normalizedString(callPayload["callId"] ?? callPayload["call_id"]) ?? "",
      ]
    )

    DispatchQueue.main.async {
      switch event {
      case "call-start":
        _ = VibeNativeCallEngine.shared.handleSignal(callPayload)
        if UIApplication.shared.applicationState != .active {
          let notificationPayload = callPayload.reduce(into: [AnyHashable: Any]()) { out, item in
            out[item.key] = item.value
          }
          _ = VibeNativeCallManager.shared.handleRemoteNotification(
            userInfo: notificationPayload,
            preferSystemUI: true
          )
        }
      case "call-end":
        var endPayload = callPayload
        endPayload["remote"] = true
        _ = VibeNativeCallEngine.shared.endCall(endPayload)
        VibeNativeCallManager.shared.clearIncomingCallUi(
          callId: self.normalizedString(callPayload["callId"] ?? callPayload["call_id"]))
      default:
        _ = VibeNativeCallEngine.shared.handleSignal(callPayload)
      }
    }
    return true
  }

  @available(iOS 13.0, *)
  private func handleNativeSocketFrame(_ frame: ChatTransportFrame) {
    let frameArrivalMs = nowMs()
    queue.async {
      if frame.event == "phx_error",
        frame.topic.hasPrefix("chat:")
      {
        let chatId = String(frame.topic.dropFirst("chat:".count))
        self.recoverStaleNativeChatTopicLocked(
          chatId: chatId,
          reason: "channel_phx_error"
        )
        return
      }

      if frame.event == "phx_reply",
        frame.topic == self.nativeUserTopic,
        let ref = frame.ref,
        ref == self.nativeUserJoinRef,
        (frame.payload["status"] as? String) == "ok"
      {
        self.nativePresenceActive = true
        self.state["presenceSource"] = "native"
        self.state["userChannelState"] = "joined"
        self.state["updatedAt"] = self.nowMs()
        self.appendJournalLocked(event: "native-user-joined", payload: ["topic": frame.topic])
        self.flushPendingCallSignalsLocked(trigger: "user_joined")
        let snapshot = self.statusSnapshotLocked()
        self.postChangeLocked(reason: "connectionStateChanged", userInfo: ["state": snapshot])
        return
      }

      if frame.event == "phx_reply", let ref = frame.ref {
        if let chatId = self.nativeChatJoinRefsByRef.removeValue(forKey: ref) {
          let status = (frame.payload["status"] as? String)?.lowercased() ?? ""
          if status == "ok" {
            self.nativeJoinedChatIds.insert(chatId)
            self.appendJournalLocked(event: "native-chat-joined", payload: ["chatId": chatId])
            self.flushPendingAgentBridgeHistoryRequestsLocked(chatId: chatId)
            self.sweepOrphanedPendingLocked(trigger: "chat_joined")
            self.ensureMlsProvisionedLocked(trigger: "chat_joined")
            self.refreshMlsPeerConfirmationLocked(chatId: chatId)
            self.establishDirectMlsOnOpenLocked(chatId: chatId)
            self.scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "chat_joined")
            self.rearmLiveBridgeSessionLocked(chatId: chatId, trigger: "chat_joined")
            self.backfillNewestChatHistoryLocked(chatId: chatId, trigger: "chat_joined")
            self.postChangeLocked(
              reason: "chatChannelStateChanged", userInfo: ["chatId": chatId])
          } else {
            self.appendJournalLocked(
              event: "native-chat-join-error",
              payload: [
                "chatId": chatId, "status": status, "payload": self.makeJSONSafeMap(frame.payload),
              ]
            )
          }
          self.state["updatedAt"] = self.nowMs()
          return
        }

        if let pending = self.nativePendingMessagePushRefs.removeValue(forKey: ref) {
          let status = (frame.payload["status"] as? String)?.lowercased() ?? ""
          let failureReason =
            status == "ok" ? "ok" : self.messagePushFailureReasonLocked(frame.payload)
          let bridgeProvider = self.bridgeProviderForChatLocked(chatId: pending.chatId)
          let replayDraft = self.pendingOutboundDraftsByMessageId[pending.messageId]
          let permanentFailure =
            status != "ok" && self.isPermanentMessagePushFailureLocked(frame.payload)
          let retryable =
            status != "ok"
            && bridgeProvider == nil
            && !permanentFailure
            && replayDraft != nil
          let staleTopic =
            status != "ok"
            && failureReason.contains("unmatched topic")
          let nextStatus = status == "ok" ? "sent" : (retryable ? "pending" : "error")
          if status != "ok" {
            let payloadKeys = frame.payload.keys.sorted().joined(separator: ",")
            NSLog(
              "[OutboundRetry] push reply chatId=%@ messageId=%@ status=%@ reason=%@ keys=%@ draft=%@ permanent=%@ retryable=%@",
              pending.chatId, pending.messageId, status, failureReason, payloadKeys,
              replayDraft == nil ? "N" : "Y",
              permanentFailure ? "Y" : "N",
              retryable ? "Y" : "N")
          }
          if let sentAtMs = self.nativeMessagePushSentAtMs.removeValue(forKey: ref) {
            let wireRTT = frameArrivalMs - sentAtMs
            let queueWait = self.nowMs() - frameArrivalMs
            NSLog(
              "[ChatEngine] ⏱️ send→%@ ack %dms (wire %dms + engineQueueWait %dms) chatId=%@ messageId=%@",
              nextStatus, Int(wireRTT + queueWait), Int(wireRTT), Int(queueWait),
              pending.chatId, pending.messageId)
          }
          if status == "ok" {
            self.cancelScheduledOutboundReplayLocked(
              messageId: pending.messageId, resetAttempt: true)
            self.removeQueuedOutboundDraftLocked(
              chatId: pending.chatId, messageId: pending.messageId, dropDraft: true)
          } else if let provider = bridgeProvider {
            self.markVolatileBridgeSendErrorLocked(
              chatId: pending.chatId,
              messageId: pending.messageId,
              reason: "push_\(status.isEmpty ? "error" : status)",
              provider: provider
            )
            return
          } else if retryable,
            let draft = replayDraft
          {
            if staleTopic {
              self.recoverStaleNativeChatTopicLocked(
                chatId: pending.chatId,
                reason: "push_unmatched_topic"
              )
            }
            self.appendJournalLocked(
              event: "native-message-push-reply",
              payload: [
                "chatId": pending.chatId,
                "messageId": pending.messageId,
                "ref": ref,
                "status": status,
                "reason": failureReason,
                "retryable": true,
              ])
            self.scheduleRetryableOutboundReplayLocked(
              chatId: pending.chatId,
              messageId: pending.messageId,
              draft: draft,
              reason: failureReason,
              recycleTransport: !staleTopic
            )
            return
          }
          self.cancelScheduledOutboundReplayLocked(
            messageId: pending.messageId, resetAttempt: true)
          self.removeQueuedOutboundDraftLocked(
            chatId: pending.chatId, messageId: pending.messageId, dropDraft: false)
          self.upsertLocalStatusLocked(
            chatId: pending.chatId, messageId: pending.messageId, status: nextStatus)
          self.appendJournalLocked(
            event: "native-message-push-reply",
            payload: [
              "chatId": pending.chatId,
              "messageId": pending.messageId,
              "ref": ref,
              "status": status,
              "reason": failureReason,
              "retryable": false,
            ])
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "messageStatusChanged",
            userInfo: [
              "chatId": pending.chatId,
              "messageId": pending.messageId,
              "status": nextStatus,
              "state": snapshot,
            ]
          )
          return
        }

        if let pending = self.nativePendingEditPushRefs.removeValue(forKey: ref) {
          let status = (frame.payload["status"] as? String)?.lowercased() ?? ""
          self.appendJournalLocked(
            event: "native-edit-message-push-reply",
            payload: [
              "chatId": pending.chatId,
              "messageId": pending.messageId,
              "ref": ref,
              "status": status,
            ])
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "chatMessageEdited",
            userInfo: [
              "chatId": pending.chatId,
              "messageId": pending.messageId,
              "action": "edited",
              "state": snapshot,
            ]
          )
          return
        }

        if let pending = self.nativePendingDeletePushRefs.removeValue(forKey: ref) {
          let status = (frame.payload["status"] as? String)?.lowercased() ?? ""
          let replyError =
            frame.payload["response"] ?? frame.payload["reason"] ?? frame.payload["error"]
          NSLog(
            "[DeleteTrace] reply chatId=%@ messageId=%@ forEveryone=%@ status=%@ error=%@",
            pending.chatId,
            pending.messageId,
            pending.forEveryone ? "true" : "false",
            status.isEmpty ? "missing" : status,
            replyError.map { String(describing: $0) } ?? "-")
          self.removeMessageIndicesLocked(chatId: pending.chatId, messageId: pending.messageId)
          self.markLiveMessageDeletedLocked(chatId: pending.chatId, messageId: pending.messageId)
          self.appendJournalLocked(
            event: "native-delete-message-push-reply",
            payload: [
              "chatId": pending.chatId,
              "messageId": pending.messageId,
              "ref": ref,
              "status": status,
              "forEveryone": pending.forEveryone,
            ])
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "chatMessageDeleted",
            userInfo: [
              "chatId": pending.chatId,
              "messageId": pending.messageId,
              "action": "deleted",
              "state": snapshot,
            ]
          )
          return
        }

        if let callSignalId = self.nativePendingCallPushRefs.removeValue(forKey: ref) {
          let status = (frame.payload["status"] as? String)?.lowercased() ?? ""
          self.appendJournalLocked(
            event: "native-call-signal-reply",
            payload: ["id": callSignalId, "ref": ref, "status": status]
          )
          self.state["updatedAt"] = self.nowMs()
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(reason: "callSignalAck", userInfo: ["state": snapshot])
          return
        }
      }

      if frame.event == "mls_welcome" {
        self.ensureMlsProvisionedLocked(trigger: "mls_welcome_push", force: true)
        return
      }
      if frame.event == "mls_welcome_acked" {
        if let chatId = self.normalizedString(frame.payload["chatId"]) {
          self.directMlsRetryWorkItemsByChat.removeValue(forKey: chatId)?.cancel()
          self.refreshMlsPeerConfirmationLocked(chatId: chatId)
          if let peerUserId = self.queuedDraftMlsPeerUserIdLocked(chatId: chatId)
            ?? self.normalizedUpper(self.chatPeerUserIdsByChatId[chatId])
          {
            self.ensureDirectMlsReadinessLocked(chatId: chatId, peerUserId: peerUserId)
          }
        }
        return
      }
      if frame.topic.hasPrefix("chat:") {
        let chatId = String(frame.topic.dropFirst(5))
        if frame.event == "agent-progress" {
          let payloadUserId = self.normalizedString(
            frame.payload["userId"] ?? frame.payload["user_id"] ?? frame.payload["id"])
          let isAgentEvent =
            (frame.payload["isAgent"] as? Bool == true)
            || payloadUserId?.lowercased() == Self.agentUserId
          if isAgentEvent {
            let label = self.normalizedString(frame.payload["label"])
            let tool = self.normalizedString(frame.payload["tool"])
            let status = self.normalizedString(frame.payload["status"]) ?? "running"
            self.setAgentProgressLocked(chatId: chatId, label: label, tool: tool, status: status)
          }
          return
        }
        if frame.event == "agent-stream" {
          self.applyAgentStreamLocked(chatId: chatId, payload: frame.payload)
          return
        }
        if frame.event == "agent-team-worker" {
          if let teamRunId = self.normalizedString(
            frame.payload["teamRunId"] ?? frame.payload["team_run_id"])
          {
            self.mergeSuppressedTeamWorkerStreamLocked(
              chatId: chatId,
              teamRunId: teamRunId,
              payload: frame.payload
            )
          }
          return
        }
        if frame.event == "agent-usage-limit" {
          let provider = self.normalizedString(frame.payload["provider"]) ?? ""
          let message = self.normalizedString(frame.payload["message"]) ?? ""
          self.postChangeLocked(
            reason: "agentUsageLimit",
            userInfo: [
              "chatId": chatId,
              "provider": provider,
              "message": message,
            ]
          )
          return
        }
        if frame.event == "agent-bridge-history" {
          self.applyAgentBridgeHistoryResultLocked(
            chatId: chatId, payload: frame.payload, transport: "cloud")
          return
        }
        if frame.event == "agent-bridge-file" {
          let requestId = self.normalizedString(frame.payload["requestId"]) ?? ""
          if !requestId.isEmpty {
            self.agentBridgeFileByRequestId[requestId] = frame.payload
          }
          self.postChangeLocked(
            reason: "agentBridgeFile",
            userInfo: [
              "chatId": chatId,
              "requestId": requestId,
              "ok": (frame.payload["ok"] as? Bool) ?? true,
            ]
          )
          return
        }
        if frame.event == "agent-bridge-usage" {
          let requestId = self.normalizedString(frame.payload["requestId"]) ?? ""
          if !requestId.isEmpty {
            self.agentBridgeUsageByRequestId[requestId] = frame.payload
          }
          let provider =
            (self.normalizedString(frame.payload["provider"])
              ?? self.normalizedString(frame.payload["agentBridgeProvider"])
              ?? "")
            .lowercased()
          if !provider.isEmpty, (frame.payload["ok"] as? Bool) ?? true {
            let key = "\(chatId)|\(provider)"
            self.agentBridgeUsageByChatProvider[key] = frame.payload
          }
          self.postChangeLocked(
            reason: "agentBridgeUsage",
            userInfo: [
              "chatId": chatId,
              "requestId": requestId,
              "provider": provider,
              "ok": (frame.payload["ok"] as? Bool) ?? true,
            ]
          )
          return
        }
        if frame.event == "agent-bridge-ask" {
          let requestId = self.normalizedString(frame.payload["requestId"]) ?? ""
          let kind = self.normalizedString(frame.payload["kind"]) ?? "ask"
          let provider = self.normalizedString(frame.payload["provider"]) ?? ""
          let sealed = frame.payload["askEnc"] != nil
          if !requestId.isEmpty {
            self.agentBridgeAskByRequestId[requestId] = frame.payload
          }
          self.agentTurnRunningAtMsByChatId[chatId] = Int64(self.nowMs())
          self.setAgentProgressLocked(
            chatId: chatId, label: "Waiting for approval", tool: nil, status: "running")
          if let expiresAtMs = self.parseLongValue(
            frame.payload["expiresAtMs"] ?? frame.payload["expires_at_ms"])
          {
            let expiryDelaySeconds = max(1.0, Double(expiresAtMs - Int64(self.nowMs())) / 1000.0)
            self.queue.asyncAfter(deadline: .now() + expiryDelaySeconds) { [weak self] in
              guard let self else { return }
              guard self.agentBridgeAskByRequestId[requestId] != nil else { return }
              self.agentBridgeAskByRequestId.removeValue(forKey: requestId)
              self.presentedAskRequestIds.remove(requestId)
              self.postChangeLocked(
                reason: "agentBridgeAskCancel",
                userInfo: ["chatId": chatId, "requestId": requestId]
              )
            }
          }
          NSLog(
            "[ChatEngine][ask] RECEIVED chat=%@ requestId=%@ kind=%@ provider=%@ sealed=%@ stored=%@ → post agentBridgeAsk",
            chatId, requestId, kind, provider, sealed ? "Y" : "N", requestId.isEmpty ? "N(empty-requestId)" : "Y"
          )
          self.postChangeLocked(
            reason: "agentBridgeAsk",
            userInfo: [
              "chatId": chatId,
              "requestId": requestId,
              "kind": kind,
              "provider": provider,
              "sessionId": self.normalizedString(
                frame.payload["sessionId"] ?? frame.payload["session_id"]) ?? "",
              "resumedFromSessionId": self.normalizedString(
                frame.payload["resumedFromSessionId"] ?? frame.payload["resumed_from_session_id"])
                ?? "",
            ]
          )
          return
        }
        if frame.event == "agent-bridge-ask-cancel" {
          let requestId = self.normalizedString(frame.payload["requestId"]) ?? ""
          if !requestId.isEmpty {
            self.agentBridgeAskByRequestId.removeValue(forKey: requestId)
            self.presentedAskRequestIds.remove(requestId)
          }
          NSLog("[ChatEngine][ask] CANCEL chat=%@ requestId=%@ → post agentBridgeAskCancel", chatId, requestId)
          self.postChangeLocked(
            reason: "agentBridgeAskCancel",
            userInfo: [
              "chatId": chatId,
              "requestId": requestId,
            ]
          )
          return
        }
        if frame.event == "agent-approval" {
          let runId = self.normalizedString(frame.payload["runId"] ?? frame.payload["run_id"]) ?? ""
          if !runId.isEmpty {
            self.activeIsolatedRunIdByChatId[chatId] = runId
          }
          if let messageId = self.normalizedString(
            frame.payload["messageId"] ?? frame.payload["message_id"]), !messageId.isEmpty
          {
            Self.storeAgentApprovalMeta(
              AgentApprovalMeta(
                kind: self.normalizedString(frame.payload["kind"]) ?? "approval",
                tool: self.normalizedString(frame.payload["tool"]) ?? "",
                detail: self.normalizedString(frame.payload["detail"]) ?? "",
                risk: (self.normalizedString(frame.payload["risk"]) ?? "").lowercased(),
                capability: self.normalizedString(frame.payload["capability"]) ?? "",
                scope: self.normalizedString(frame.payload["scope"]) ?? "",
                reason: self.normalizedString(frame.payload["reason"]) ?? ""),
              messageId: messageId)
          }
          self.agentTurnRunningAtMsByChatId[chatId] = Int64(self.nowMs())
          self.setAgentProgressLocked(
            chatId: chatId, label: "Waiting for approval", tool: nil, status: "running")
          return
        }
        if frame.event == "agent-run-state" {
          let runId = self.normalizedString(frame.payload["runId"] ?? frame.payload["run_id"]) ?? ""
          let status = (self.normalizedString(frame.payload["status"]) ?? "").lowercased()
          let reason = self.normalizedString(frame.payload["reason"]) ?? ""
          let staleRun =
            !runId.isEmpty && self.activeIsolatedRunIdByChatId[chatId] != nil
            && self.activeIsolatedRunIdByChatId[chatId] != runId
          guard !staleRun, ["completed", "failed", "cancelled"].contains(status) else { return }
          self.activeIsolatedRunIdByChatId.removeValue(forKey: chatId)
          self.agentTurnRunningAtMsByChatId.removeValue(forKey: chatId)
          if let last = self.latestAgentComputer(chatId: chatId), last.live {
            Self.storeAgentComputer(
              AgentComputerState(
                url: last.url, title: last.title, live: false, holder: last.holder,
                runId: last.runId, agentUserId: last.agentUserId,
                updatedAtMs: Int64(self.nowMs())),
              chatId: chatId, agentUserId: last.agentUserId)
          }
          let settleStatus = status == "completed" ? "done" : (status == "failed" ? "error" : "stopped")
          self.clearAgentProgressLocked(
            chatId: chatId, status: settleStatus, reason: "runState(\(status):\(reason))")
          return
        }
        if frame.event == "agent-preview" {
          let runId = self.normalizedString(frame.payload["runId"] ?? frame.payload["run_id"]) ?? ""
          let label = self.normalizedString(frame.payload["label"]) ?? "Computer"
          if let b64 = frame.payload["imageBase64"] as? String,
            let data = Data(base64Encoded: b64),
            let image = UIImage(data: data)
          {
            let agentUserId = self.normalizedString(frame.payload["agentUserId"]) ?? ""
            self.latestAgentPreviewByChatId[
              Self.agentComputerKey(chatId: chatId, agentUserId: agentUserId)] =
              AgentPreviewState(
                image: image, label: label, runId: runId, agentUserId: agentUserId,
                updatedAtMs: Int64(self.nowMs()))
            self.postChangeLocked(
              reason: "agentPreview",
              userInfo: ["chatId": chatId, "runId": runId, "agentUserId": agentUserId])
          }
          return
        }
        if frame.event == "agent-computer" {
          let runId = self.normalizedString(frame.payload["runId"] ?? frame.payload["run_id"]) ?? ""
          let agentUserId = self.normalizedString(frame.payload["agentUserId"]) ?? ""
          let previous = self.latestAgentComputer(chatId: chatId, agentUserId: agentUserId)
          let live: Bool = {
            switch frame.payload["live"] {
            case let value as Bool: return value
            case let value as NSNumber: return value.boolValue
            case let value as String: return ["1", "true", "yes"].contains(value.lowercased())
            default: return previous?.live ?? false
            }
          }()
          let state = AgentComputerState(
            url: self.normalizedString(frame.payload["url"]) ?? previous?.url ?? "",
            title: self.normalizedString(frame.payload["title"]) ?? previous?.title ?? "",
            live: live,
            holder: self.normalizedString(frame.payload["holder"]) ?? previous?.holder,
            runId: runId.isEmpty ? (previous?.runId ?? "") : runId,
            agentUserId: agentUserId,
            updatedAtMs: Int64(self.nowMs()))
          Self.storeAgentComputer(state, chatId: chatId, agentUserId: agentUserId)
          self.postChangeLocked(
            reason: "agentComputer",
            userInfo: [
              "chatId": chatId, "runId": runId, "live": live, "agentUserId": agentUserId,
            ])
          if live, !state.host.isEmpty {
            self.setAgentProgressLocked(
              chatId: chatId, label: "Browsing \(state.host)", tool: "computer", status: "running")
          } else if live, state.isShell, !state.title.isEmpty {
            self.setAgentProgressLocked(
              chatId: chatId, label: "Running \(state.title)", tool: "computer", status: "running")
          }
          return
        }
        if frame.event == "typing" || frame.event == "stop-typing" {
          let typing = frame.event == "typing"
          let payloadUserId = self.normalizedUpper(
            frame.payload["userId"] ?? frame.payload["user_id"] ?? frame.payload["id"])
          let myUserId = self.normalizedUpper(self.getConfigValueLocked("userId"))
          var typingUsers = self.peerTypingUserIdsByChatId[chatId] ?? Set<String>()
          var typingSeenAt = self.peerTypingSeenAtMsByChatId[chatId] ?? [:]
          if let payloadUserId, payloadUserId != myUserId {
            if typing {
              typingUsers.insert(payloadUserId)
              typingSeenAt[payloadUserId] = Int64(self.nowMs())
            } else {
              typingUsers.remove(payloadUserId)
              typingSeenAt.removeValue(forKey: payloadUserId)
            }
            if typingUsers.isEmpty {
              self.peerTypingUserIdsByChatId.removeValue(forKey: chatId)
              self.peerTypingSeenAtMsByChatId.removeValue(forKey: chatId)
            } else {
              self.peerTypingUserIdsByChatId[chatId] = typingUsers
              self.peerTypingSeenAtMsByChatId[chatId] = typingSeenAt
              self.schedulePeerTypingExpiryLocked()
            }
          } else if !typing {
            self.peerTypingUserIdsByChatId.removeValue(forKey: chatId)
            self.peerTypingSeenAtMsByChatId.removeValue(forKey: chatId)
            typingUsers.removeAll()
          }
          if !typing, payloadUserId?.lowercased() == Self.agentUserId {
            let sinceRunningMs =
              Int64(self.nowMs()) - (self.agentTurnRunningAtMsByChatId[chatId] ?? 0)
            let askOutstanding = self.agentBridgeAskByRequestId.values.contains { payload in
              (self.normalizedString(payload["chatId"]) ?? "") == chatId
            }
            if askOutstanding || sinceRunningMs < Self.agentTurnRunningGraceMs {
              VibeDebugLog.log(
                "[EmptyTrace] agentTypingStopped HOLD chatId=%@ ask=%@ sinceRunningMs=%lld",
                String(chatId.suffix(12)), askOutstanding ? "Y" : "N", sinceRunningMs)
            } else {
              self.clearAgentProgressLocked(chatId: chatId, status: "done", reason: "agentTypingStopped(A)")
            }
          }
          let typingUserIds = Array(typingUsers).sorted()
          let isAnyTyping = !typingUserIds.isEmpty || (typing && payloadUserId == nil)
          self.postChangeLocked(
            reason: "peerTyping",
            userInfo: [
              "chatId": chatId,
              "messageId": isAnyTyping ? "true" : "false",  // Kept for ChatListView compatibility.
              "typingUserIds": typingUserIds,
            ]
          )
          return
        }
        if frame.event == "pinned-updated" {
          guard
            let messageId = self.normalizedString(
              frame.payload["messageId"] ?? frame.payload["message_id"])
          else { return }
          let pinned = self.parseBooleanLike(frame.payload["pinned"]) ?? true
          NSLog(
            "[ChatEngine][Pin] socket pinned-updated chatId=%@ messageId=%@ pinned=%@ payloadKeys=%@",
            chatId,
            messageId,
            pinned ? "true" : "false",
            Array(frame.payload.keys).sorted().joined(separator: ",")
          )
          self.applyPinnedUpdateLocked(
            chatId: chatId,
            messageId: messageId,
            pinned: pinned,
            payload: frame.payload,
            trigger: "socket_pinned_updated",
            refreshRemote: true
          )
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "chatPinnedUpdated",
            userInfo: [
              "chatId": chatId,
              "messageId": messageId,
              "pinned": pinned,
              "state": snapshot,
            ]
          )
          return
        }
        let incomingMessageId = self.normalizedString(frame.payload["id"] ?? frame.payload["message_id"])
        let incomingMessageWasPresent = incomingMessageId.map { messageId in
          self.liveMessageRowsByChat[chatId]?[messageId] != nil
            || (self.historyRowsByChat[chatId] ?? []).contains {
              self.messageId(fromRow: $0) == messageId
            }
        } ?? false
        if frame.event == "message",
          let insertedMessageId = self.applyNativeIncomingMessageEventLocked(
            chatId: chatId, payload: frame.payload, postDelta: false)
        {
          let fromId = self.normalizedString(frame.payload["fromId"] ?? frame.payload["from_id"])
          let isAgentMessage =
            (frame.payload["isAgentMessage"] as? Bool == true)
            || fromId?.lowercased() == Self.agentUserId
            || (fromId.map { Self.reservedBridgeAgentUserIds.contains($0.lowercased()) } ?? false)
          var removedStreamIds: [String] = []
          if isAgentMessage {
            let othersStillTyping: Bool = {
              guard let typers = self.peerTypingUserIdsByChatId[chatId], !typers.isEmpty else {
                return false
              }
              let sender = self.normalizedUpper(fromId)
              return typers.contains { self.normalizedUpper($0) != sender }
            }()
            if !othersStillTyping {
              self.clearAgentProgressLocked(
                chatId: chatId, status: "done", reason: "agentPersistedMessage")
            }
            let removal = self.removeAgentStreamRowsLocked(chatId: chatId, agentUserId: fromId)
            removedStreamIds = removal.removedIds
            if let slotTs = removal.slotTs {
              self.adoptAgentSettleSlotTsLocked(
                chatId: chatId, messageId: insertedMessageId, slotTs: slotTs)
            }
          }

          let myUserId = self.normalizedUpper(self.getConfigValueLocked("userId"))
          let isMe = self.normalizedUpper(fromId) == myUserId

          if !isMe {
            _ = self.sendDeliveryReceipt([
              "chatId": chatId,
              "messageId": insertedMessageId,
            ])
          }

          if var typingUsers = self.peerTypingUserIdsByChatId[chatId], !typingUsers.isEmpty {
            if let senderUpper = self.normalizedUpper(fromId) {
              typingUsers = typingUsers.filter { self.normalizedUpper($0) != senderUpper }
            } else {
              typingUsers = []
            }
            if typingUsers != self.peerTypingUserIdsByChatId[chatId] {
              if typingUsers.isEmpty {
                self.peerTypingUserIdsByChatId.removeValue(forKey: chatId)
              } else {
                self.peerTypingUserIdsByChatId[chatId] = typingUsers
              }
              self.postChangeLocked(
                reason: "peerTyping",
                userInfo: [
                  "chatId": chatId,
                  "messageId": typingUsers.isEmpty ? "false" : "true",
                  "typingUserIds": Array(typingUsers).sorted(),
                ]
              )
            }
          }
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "chatMessageInserted",
            userInfo: [
              "chatId": chatId,
              "messageId": insertedMessageId,
              "state": snapshot,
            ]
          )
          self.postChatDeltaLocked(
            chatId: chatId,
            inserted: incomingMessageWasPresent ? [] : [insertedMessageId],
            updated: incomingMessageWasPresent ? [insertedMessageId] : [],
            deleted: removedStreamIds,
            source: removedStreamIds.isEmpty ? "live" : "streamSettle")
          return
        }
        if frame.event == "message-reaction-updated",
          let messageId = self.normalizedString(
            frame.payload["messageId"] ?? frame.payload["message_id"]),
          let incoming = frame.payload["reactions"] as? [[String: Any]]
        {
          let selectedEmoji = (self.findMessagePayloadLocked(
            chatId: chatId, messageId: messageId)?["reactions"] as? [[String: Any]])?
            .first(where: {
              self.parseBooleanLike($0["isSelected"] ?? $0["is_selected"]) == true
            }).flatMap { self.normalizedString($0["emoji"]) }
          let reactions = incoming.map { bucket -> [String: Any] in
            var next = bucket
            next["isSelected"] = self.normalizedString(bucket["emoji"]) == selectedEmoji
            return next
          }
          self.applyMessageEngagementLocked(
            chatId: chatId, messageId: messageId, reactions: reactions, viewCount: nil)
          self.postChangeLocked(
            reason: "chatMessageReactionChanged",
            userInfo: ["chatId": chatId, "messageId": messageId])
          self.postChatDeltaLocked(
            chatId: chatId, inserted: [], updated: [messageId], deleted: [],
            source: "reaction")
          return
        }
        if frame.event == "message-view-counts-updated",
          let counts = frame.payload["counts"] as? [[String: Any]]
        {
          var changedIds: [String] = []
          for count in counts.prefix(200) {
            guard let messageId = self.normalizedString(
              count["messageId"] ?? count["message_id"]),
              let viewCount = self.parseLongValue(count["viewCount"] ?? count["view_count"])
            else { continue }
            if self.applyMessageEngagementLocked(
              chatId: chatId, messageId: messageId, reactions: nil, viewCount: viewCount)
            {
              changedIds.append(messageId)
            }
          }
          if !changedIds.isEmpty {
            self.postChangeLocked(
              reason: "chatMessageViewCountChanged",
              userInfo: ["chatId": chatId, "messageIds": changedIds])
            self.postChatDeltaLocked(
              chatId: chatId, inserted: [], updated: changedIds, deleted: [], source: "views")
          }
          return
        }
        if let mutationUpdate = self.applyNativeChatMutationEventLocked(
          chatId: chatId, event: frame.event, payload: frame.payload)
        {
          let reason: String = {
            switch mutationUpdate.action {
            case "edited": return "chatMessageEdited"
            case "deleted": return "chatMessageDeleted"
            default: return "chatMessageChanged"
            }
          }()
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: reason,
            userInfo: [
              "chatId": chatId,
              "messageId": mutationUpdate.messageId,
              "action": mutationUpdate.action,
              "state": snapshot,
            ]
          )
          switch mutationUpdate.action {
          case "edited":
            self.postChatDeltaLocked(
              chatId: chatId, inserted: [], updated: [mutationUpdate.messageId], deleted: [],
              source: "edit")
          case "deleted":
            self.postChatDeltaLocked(
              chatId: chatId, inserted: [], updated: [], deleted: [mutationUpdate.messageId],
              source: "delete")
          default:
            break
          }
          return
        }
        if let receiptUpdate = self.applyNativeChatEventLocked(
          chatId: chatId, event: frame.event, payload: frame.payload)
        {
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "messageStatusChanged",
            userInfo: [
              "chatId": chatId,
              "messageId": receiptUpdate.messageId,
              "status": receiptUpdate.status,
              "state": snapshot,
            ]
          )
          return
        }
      }

      guard frame.topic == self.nativeUserTopic else { return }
      if frame.event == "bridge-status" {
        let payload = frame.payload
        DispatchQueue.main.async {
          AgentPairingService.ingestSocketStatusSnapshot(payload)
        }
        return
      }
      if frame.event == "chat-deleted" {
        guard
          let chatId = self.normalizedString(
            frame.payload["chatId"] ?? frame.payload["chat_id"]),
          !chatId.isEmpty
        else { return }
        self.clearChatStateLocked(chatId: chatId, journalEvent: "native-chat-clear-remote")
        return
      }
      if frame.event == "message-edited" || frame.event == "message-deleted" {
        guard
          let chatId = self.normalizedString(
            frame.payload["chatId"] ?? frame.payload["chat_id"]),
          !chatId.isEmpty
        else { return }
        guard !self.nativeJoinedChatIds.contains(chatId) else { return }
        guard
          let mutationUpdate = self.applyNativeChatMutationEventLocked(
            chatId: chatId, event: frame.event, payload: frame.payload)
        else {
          self.postChangeLocked(
            reason: "remoteChatMutationMiss",
            userInfo: [
              "chatId": chatId,
              "messageId": self.normalizedString(
                frame.payload["messageId"] ?? frame.payload["message_id"]) as Any,
              "chatIsOnScreen": false,
              "state": self.statusSnapshotLocked(),
            ]
          )
          return
        }
        let reason =
          mutationUpdate.action == "edited" ? "chatMessageEdited" : "chatMessageDeleted"
        self.postChangeLocked(
          reason: reason,
          userInfo: [
            "chatId": chatId,
            "messageId": mutationUpdate.messageId,
            "action": mutationUpdate.action,
            "chatIsOnScreen": false,
            "state": self.statusSnapshotLocked(),
          ]
        )
        if mutationUpdate.action == "edited" {
          self.postChatDeltaLocked(
            chatId: chatId, inserted: [], updated: [mutationUpdate.messageId], deleted: [],
            source: "userTopicEdit")
        } else {
          self.postChatDeltaLocked(
            chatId: chatId, inserted: [], updated: [], deleted: [mutationUpdate.messageId],
            source: "userTopicDelete")
        }
        return
      }
      if frame.event == "message-delivered" || frame.event == "message-read" {
        guard
          let chatId = self.normalizedString(
            frame.payload["chatId"] ?? frame.payload["chat_id"]),
          !chatId.isEmpty
        else { return }
        guard !self.nativeJoinedChatIds.contains(chatId) else { return }
        guard
          let receiptUpdate = self.applyNativeChatEventLocked(
            chatId: chatId, event: frame.event, payload: frame.payload)
        else { return }
        self.postChangeLocked(
          reason: "messageStatusChanged",
          userInfo: [
            "chatId": chatId,
            "messageId": receiptUpdate.messageId,
            "status": receiptUpdate.status,
            "chatIsOnScreen": false,
            "state": self.statusSnapshotLocked(),
          ]
        )
        return
      }
      if frame.event == "new_message" {
        let signalChatId = self.normalizedString(
          frame.payload["chatId"] ?? frame.payload["chat_id"])
        var ingested: (messageId: String, inserted: Bool)?
        if let chatId = signalChatId, !chatId.isEmpty,
          let mirrored = frame.payload["message"] as? [String: Any],
          !mirrored.isEmpty
        {
          ingested = self.ingestMirroredUserTopicMessageLocked(
            chatId: chatId, payload: mirrored)
        }
        var userInfo: [String: Any] = [
          "chatId": signalChatId ?? "",
          "state": self.statusSnapshotLocked(),
          "chatIsOnScreen": signalChatId.map { self.nativeJoinedChatIds.contains($0) } ?? false,
        ]
        if let ingested {
          userInfo["messageId"] = ingested.messageId
          userInfo["inserted"] = ingested.inserted
        }
        self.postChangeLocked(reason: "remoteNewMessage", userInfo: userInfo)
        return
      }
      if self.handleUserCallEventLocked(event: frame.event, payload: frame.payload) {
        let snapshot = self.statusSnapshotLocked()
        self.postChangeLocked(
          reason: "callSignalReceived",
          userInfo: ["event": frame.event, "state": snapshot]
        )
        return
      }
      let previouslyOnline = self.onlineUsers
      if self.applyPresenceEventLocked(event: frame.event, payload: frame.payload) {
        self.resumeDirectMlsReadinessLocked(
          newlyOnlineUserIds: self.onlineUsers.subtracting(previouslyOnline))
        self.state["presenceSource"] = "native"
        self.state["updatedAt"] = self.nowMs()
        let snapshot = self.statusSnapshotLocked()
        self.postChangeLocked(
          reason: "presenceChanged",
          userInfo: ["onlineCount": self.onlineUsers.count, "state": snapshot]
        )
      }
    }
  }

  private func applyPresenceEventLocked(event: String, payload: [String: Any]) -> Bool {
    switch event {
    case "initial-presence":
      let ids = (payload["onlineFriendIds"] as? [Any])?.compactMap { normalizedUpper($0) } ?? []
      onlineUsers = Set(ids)
      for userId in ids {
        lastSeenByUserId.removeValue(forKey: userId)
      }
      appendJournalLocked(event: "native-presence-initial", payload: ["count": ids.count])
      return true
    case "friend-online":
      if let userId = normalizedUpper(payload["userId"] ?? payload["user_id"] ?? payload["id"]) {
        onlineUsers.insert(userId)
        lastSeenByUserId.removeValue(forKey: userId)
        appendJournalLocked(event: "native-presence-online", payload: ["userId": userId])
        return true
      }
      return false
    case "friend-offline":
      if let userId = normalizedUpper(payload["userId"] ?? payload["user_id"] ?? payload["id"]) {
        onlineUsers.remove(userId)
        let lastSeen =
          parseLongValue(
            payload["lastSeenMs"] ?? payload["last_seen_ms"] ?? payload["lastSeen"]
              ?? payload["last_seen"])
          ?? Int64(nowMs())
        lastSeenByUserId[userId] = lastSeen
        appendJournalLocked(
          event: "native-presence-offline",
          payload: ["userId": userId, "lastSeenMs": lastSeen])
        return true
      }
      return false
    case "presence_state":
      let ids = payload.keys.compactMap { normalizedUpper($0) }
      onlineUsers = Set(ids)
      for userId in ids {
        lastSeenByUserId.removeValue(forKey: userId)
      }
      appendJournalLocked(event: "native-presence-state", payload: ["count": ids.count])
      return true
    case "presence_diff", "presence-diff":
      let joins = payload["joins"] as? [String: Any] ?? [:]
      let leaves = payload["leaves"] as? [String: Any] ?? [:]
      for id in joins.keys {
        if let normalized = normalizedUpper(id) {
          onlineUsers.insert(normalized)
          lastSeenByUserId.removeValue(forKey: normalized)
        }
      }
      for id in leaves.keys {
        if let normalized = normalizedUpper(id) {
          onlineUsers.remove(normalized)
          lastSeenByUserId[normalized] = Int64(nowMs())
        }
      }
      appendJournalLocked(
        event: "native-presence-diff",
        payload: [
          "joins": joins.keys.count,
          "leaves": leaves.keys.count,
        ])
      return true
    default:
      return false
    }
  }

  private func getConfigValueLocked(_ key: String) -> Any? {
    store.getConfig()[key]
  }

  private func transportModeLocked(config: [String: Any]? = nil) -> String {
    let resolvedConfig = config ?? store.getConfig()
    let mode =
      normalizedString(resolvedConfig["transportMode"])?.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).lowercased()
    switch mode {
    case "bridge_text", "offline":
      return mode ?? "direct"
    default:
      return "direct"
    }
  }

  private func packetProxyEnabledLocked(config: [String: Any]? = nil) -> Bool {
    let resolvedConfig = config ?? store.getConfig()
    return parseBooleanLike(resolvedConfig["packetProxyEnabled"]) ?? false
  }

  private func isBridgeTextModeLocked(config: [String: Any]? = nil) -> Bool {
    transportModeLocked(config: config) == "bridge_text"
  }

  private func packetProxyPortLocked(config: [String: Any]? = nil) -> Int? {
    let resolvedConfig = config ?? store.getConfig()
    if let value = resolvedConfig["packetProxyPort"] as? NSNumber {
      return value.intValue
    }
    if let value = normalizedString(resolvedConfig["packetProxyPort"]), let port = Int(value) {
      return port
    }
    return nil
  }

  private func packetProxyHostLocked(config: [String: Any]? = nil) -> String {
    let resolvedConfig = config ?? store.getConfig()
    return normalizedString(resolvedConfig["packetProxyHost"]) ?? "127.0.0.1"
  }

  private func disableMediaLocked(config: [String: Any]? = nil) -> Bool {
    let resolvedConfig = config ?? store.getConfig()
    return parseBooleanLike(resolvedConfig["disableMedia"])
      ?? isBridgeTextModeLocked(config: resolvedConfig)
  }

  private func disableCallsLocked(config: [String: Any]? = nil) -> Bool {
    let resolvedConfig = config ?? store.getConfig()
    return parseBooleanLike(resolvedConfig["disableCalls"])
      ?? isBridgeTextModeLocked(config: resolvedConfig)
  }

  private func disableRemoteAvatarsLocked(config: [String: Any]? = nil) -> Bool {
    let resolvedConfig = config ?? store.getConfig()
    return parseBooleanLike(resolvedConfig["disableRemoteAvatars"])
      ?? isBridgeTextModeLocked(config: resolvedConfig)
  }

  private func bridgeBaseURLLocked(config: [String: Any]? = nil) -> URL? {
    let resolvedConfig = config ?? store.getConfig()
    if let explicit = normalizedString(resolvedConfig["bridgeBaseUrl"]), let url = URL(string: explicit) {
      return url
    }
    let activeBridgeId = normalizedString(resolvedConfig["activeBridgeId"])
    let bundle = resolvedConfig["bridgeBundle"] as? [String: Any]
    let descriptors = bundle?["descriptors"] as? [[String: Any]] ?? []
    let preferred =
      descriptors.first(where: { normalizedString($0["id"]) == activeBridgeId })
      ?? descriptors.sorted { left, right in
        let leftPriority = parseLongValue(left["priority"]) ?? 999
        let rightPriority = parseLongValue(right["priority"]) ?? 999
        return leftPriority < rightPriority
      }.first
    guard let preferred else { return nil }
    if let baseUrl = normalizedString(preferred["baseUrl"]), let url = URL(string: baseUrl) {
      return url
    }
    guard let host = normalizedString(preferred["host"]) else { return nil }
    let transport = normalizedString(preferred["transport"]) == "http" ? "http" : "https"
    let port = parseLongValue(preferred["port"]).map { ":\($0)" } ?? ""
    let pathPrefix =
      normalizedString(preferred["pathPrefix"])?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let suffix = (pathPrefix?.isEmpty == false) ? "/\(pathPrefix!)" : ""
    return URL(string: "\(transport)://\(host)\(port)\(suffix)")
  }

  private func bridgeURLLocked(_ path: String, config: [String: Any]? = nil) -> URL? {
    guard let base = bridgeBaseURLLocked(config: config) else { return nil }
    let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return base.appendingPathComponent(trimmed)
  }

  private func extractPublicKeyValue(from data: [String: Any]) -> String? {
    normalizedString(data["publicKey"])
      ?? normalizedString(data["friendKey"])
      ?? normalizedString(data["friendPublicKey"])
      ?? normalizedString(data["public_key"])
      ?? normalizedString(data["public_key_pem"])
      ?? ((data["data"] as? [String: Any]).flatMap(extractPublicKeyValue(from:)))
      ?? ((data["user"] as? [String: Any]).flatMap(extractPublicKeyValue(from:)))
      ?? ((data["friend"] as? [String: Any]).flatMap(extractPublicKeyValue(from:)))
  }

  private func resolveFriendPublicKeyLocked(chatId: String, peerUserIdHint: String?) -> String? {
    let resolvedPeerId = peerUserIdHint ?? chatPeerUserIdsByChatId[chatId]
    if let resolvedPeerId {
      chatPeerUserIdsByChatId[chatId] = resolvedPeerId
    }
    if let resolvedPeerId, let cached = friendPublicKeysByUserId[resolvedPeerId] {
      return cached
    }
    return nil
  }

  private static let claudeBridgeAgentUserId = "11111111-1111-1111-1111-111111111111"
  private static let codexBridgeAgentUserId = "22222222-2222-2222-2222-222222222222"
  private static let grokBridgeAgentUserId = "33333333-3333-3333-3333-333333333333"
  private static let agyBridgeAgentUserId = "44444444-4444-4444-4444-444444444444"
  private static let reservedBridgeAgentUserIds: Set<String> = [
    claudeBridgeAgentUserId,
    codexBridgeAgentUserId,
    grokBridgeAgentUserId,
    agyBridgeAgentUserId,
  ]

  private static let bridgeAgentProvidersByUserId: [String: String] = [
    claudeBridgeAgentUserId: "claude",
    codexBridgeAgentUserId: "codex",
    grokBridgeAgentUserId: "grok",
    agyBridgeAgentUserId: "agy",
  ]

  private static func bridgeAgentUserId(forProvider provider: String) -> String? {
    switch provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "claude": return claudeBridgeAgentUserId
    case "codex": return codexBridgeAgentUserId
    case "grok": return grokBridgeAgentUserId
    case "agy", "antigravity": return agyBridgeAgentUserId
    default: return nil
    }
  }

  private func bridgeProviderForAgentIdentifier(_ raw: String?) -> String? {
    guard let value = normalizedString(raw)?.lowercased() else { return nil }
    switch value {
    case "claude", Self.claudeBridgeAgentUserId:
      return "claude"
    case "codex", Self.codexBridgeAgentUserId:
      return "codex"
    case "grok", Self.grokBridgeAgentUserId:
      return "grok"
    case "agy", "antigravity", Self.agyBridgeAgentUserId:
      return "agy"
    default:
      return nil
    }
  }

  private func bridgeProviderForMetadata(_ metadata: [String: Any]) -> String? {
    bridgeProviderForAgentIdentifier(
      normalizedString(metadata["agentBridgeProvider"] ?? metadata["agent_bridge_provider"] ?? metadata["provider"]))
  }

  private func bridgeProviderForChatLocked(
    chatId: String?,
    peerUserId: String? = nil,
    peerAgentId: String? = nil,
    metadata: [String: Any] = [:]
  ) -> String? {
    if let provider = bridgeProviderForMetadata(metadata) {
      return provider
    }
    if let provider = bridgeProviderForAgentIdentifier(peerAgentId) {
      return provider
    }
    if let peer = normalizedString(peerUserId)?.lowercased(),
      let provider = Self.bridgeAgentProvidersByUserId[peer]
    {
      return provider
    }
    guard let chatId, !chatId.isEmpty else { return nil }
    if let cachedAgentId = chatPeerAgentIdsByChatId[chatId],
      let provider = bridgeProviderForAgentIdentifier(cachedAgentId)
    {
      return provider
    }
    if let cachedPeer = chatPeerUserIdsByChatId[chatId]?.lowercased(),
      let provider = Self.bridgeAgentProvidersByUserId[cachedPeer]
    {
      return provider
    }
    return nil
  }

  private func isVolatileBridgeAgentChatLocked(
    chatId: String?,
    peerUserId: String? = nil,
    peerAgentId: String? = nil,
    metadata: [String: Any] = [:]
  ) -> Bool {
    let isAgent =
      bridgeProviderForChatLocked(
        chatId: chatId,
        peerUserId: peerUserId,
        peerAgentId: peerAgentId,
        metadata: metadata
      ) != nil
    if isAgent, let chatId, !chatId.isEmpty {
      markAgentDMChatForPersistenceLocked(chatId: chatId)
    }
    return isAgent
  }

  private func resolvePeerAgentIdLocked(chatId: String, peerUserIdHint: String?) -> String? {
    if let cached = chatPeerAgentIdsByChatId[chatId], !cached.isEmpty {
      return cached
    }
    let resolvedPeerId = peerUserIdHint ?? chatPeerUserIdsByChatId[chatId]
    guard let resolvedPeerId else { return nil }
    if let mapped = agentIdsByPeerUserId[resolvedPeerId] { return mapped }
    if Self.reservedBridgeAgentUserIds.contains(resolvedPeerId.lowercased()) {
      return resolvedPeerId
    }
    return nil
  }

  private func scheduleFriendPublicKeyRetryLocked(peerId: String, reason: String) {
    guard pendingFriendKeyChatIdsByUserId[peerId]?.isEmpty == false else {
      friendKeyRetryWorkItemsByUserId[peerId]?.cancel()
      friendKeyRetryWorkItemsByUserId.removeValue(forKey: peerId)
      return
    }
    guard friendKeyRetryWorkItemsByUserId[peerId] == nil else { return }

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.queue.async {
        self.friendKeyRetryWorkItemsByUserId.removeValue(forKey: peerId)
        guard let chatId = self.pendingFriendKeyChatIdsByUserId[peerId]?.first else { return }
        self.scheduleFriendPublicKeyFetchLocked(
          chatId: chatId,
          peerUserIdHint: peerId,
          trigger: "retry_\(reason)"
        )
      }
    }
    friendKeyRetryWorkItemsByUserId[peerId] = workItem
    queue.asyncAfter(deadline: .now() + 1.0, execute: workItem)
  }

  private func scheduleFriendPublicKeyFetchLocked(
    chatId: String,
    peerUserIdHint: String?,
    trigger: String
  ) {
    let resolvedPeerId = (peerUserIdHint ?? chatPeerUserIdsByChatId[chatId])?.uppercased()
    guard let peerId = resolvedPeerId, !peerId.isEmpty else { return }
    chatPeerUserIdsByChatId[chatId] = peerId
    if friendPublicKeysByUserId[peerId] != nil {
      scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "friend_key_cached")
      return
    }

    var pendingChats = pendingFriendKeyChatIdsByUserId[peerId] ?? Set<String>()
    pendingChats.insert(chatId)
    pendingFriendKeyChatIdsByUserId[peerId] = pendingChats

    guard !friendKeyFetchInFlightUserIds.contains(peerId) else { return }
    let isBridgeText = isBridgeTextModeLocked()
    guard let token = authHeaderTokenLocked() else { return }
    let requestURL: URL? =
      isBridgeText
      ? bridgeURLLocked("/bridge/v1/keys/peer")
      : apiBaseURLLocked()?.appendingPathComponent("api").appendingPathComponent("user")
        .appendingPathComponent(peerId)
    guard let requestURL else { return }

    friendKeyRetryWorkItemsByUserId[peerId]?.cancel()
    friendKeyRetryWorkItemsByUserId.removeValue(forKey: peerId)
    friendKeyFetchInFlightUserIds.insert(peerId)

    var request = URLRequest(url: requestURL)
    request.httpMethod = isBridgeText ? "POST" : "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if isBridgeText {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 8.0
    if isBridgeText {
      request.httpBody = try? JSONSerialization.data(
        withJSONObject: ["peerUserId": peerId, "chatId": chatId], options: [])
    }
    appendJournalLocked(
      event: "friend-key-fetch-start",
      payload: ["peerUserId": peerId, "chatId": chatId, "trigger": trigger]
    )
    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      self.queue.async {
        self.friendKeyFetchInFlightUserIds.remove(peerId)

        let statusCode = (response as? HTTPURLResponse)?.statusCode
        let parsedObject: [String: Any]? = {
          guard error == nil,
            let statusCode,
            (200...299).contains(statusCode),
            let data
          else { return nil }
          return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }()
        let resolvedKey: String? = {
          guard let obj = parsedObject else { return nil }
          return
            self.normalizedString(obj["publicKey"])
            ?? self.normalizedString(obj["friendKey"])
            ?? self.normalizedString(obj["friendPublicKey"])
            ?? self.normalizedString(obj["public_key"])
            ?? self.normalizedString(obj["public_key_pem"])
            ?? ((obj["data"] as? [String: Any]).flatMap(self.extractPublicKeyValue(from:)))
            ?? ((obj["user"] as? [String: Any]).flatMap(self.extractPublicKeyValue(from:)))
            ?? ((obj["friend"] as? [String: Any]).flatMap(self.extractPublicKeyValue(from:)))
        }()
        let resolvedAgentId: String? = {
          guard let obj = parsedObject else { return nil }
          let nested = obj["data"] as? [String: Any]
          let isAgent =
            (obj["isAgent"] as? Bool == true)
            || (nested?["isAgent"] as? Bool == true)
          guard isAgent else { return nil }
          return
            self.normalizedString(obj["agentId"] ?? obj["agent_id"])
            ?? self.normalizedString(nested?["agentId"] ?? nested?["agent_id"])
        }()

        let waitingChatIds = Array(self.pendingFriendKeyChatIdsByUserId[peerId] ?? [])
        if let resolvedAgentId, !resolvedAgentId.isEmpty {
          self.agentIdsByPeerUserId[peerId] = resolvedAgentId
          for waitingChatId in waitingChatIds {
            self.chatPeerAgentIdsByChatId[waitingChatId] = resolvedAgentId
          }
        }
        if let resolvedKey {
          self.friendPublicKeysByUserId[peerId] = resolvedKey
          for waitingChatId in waitingChatIds {
            self.chatPeerUserIdsByChatId[waitingChatId] = peerId
          }
          self.pendingFriendKeyChatIdsByUserId.removeValue(forKey: peerId)
          self.friendKeyRetryWorkItemsByUserId[peerId]?.cancel()
          self.friendKeyRetryWorkItemsByUserId.removeValue(forKey: peerId)
          self.appendJournalLocked(
            event: "friend-key-fetch-ok",
            payload: ["peerUserId": peerId, "chatCount": waitingChatIds.count]
          )
          for waitingChatId in waitingChatIds {
            self.scheduleReplayQueuedOutboundLocked(
              chatId: waitingChatId, trigger: "friend_key_loaded")
          }
          return
        }

        if let resolvedAgentId, !resolvedAgentId.isEmpty {
          self.pendingFriendKeyChatIdsByUserId.removeValue(forKey: peerId)
          self.friendKeyRetryWorkItemsByUserId[peerId]?.cancel()
          self.friendKeyRetryWorkItemsByUserId.removeValue(forKey: peerId)
          self.appendJournalLocked(
            event: "friend-key-fetch-agent-ok",
            payload: [
              "peerUserId": peerId,
              "chatCount": waitingChatIds.count,
              "agentId": resolvedAgentId,
            ]
          )
          for waitingChatId in waitingChatIds {
            self.scheduleReplayQueuedOutboundLocked(
              chatId: waitingChatId, trigger: "peer_agent_loaded")
          }
          return
        }

        self.appendJournalLocked(
          event: "friend-key-fetch-error",
          payload: [
            "peerUserId": peerId,
            "chatCount": waitingChatIds.count,
            "status": statusCode as Any,
            "error": error?.localizedDescription as Any,
          ])
        let shouldRetry = waitingChatIds.contains {
          !(self.pendingOutboundQueueByChat[$0]?.isEmpty ?? true)
        }
        if shouldRetry {
          self.scheduleFriendPublicKeyRetryLocked(peerId: peerId, reason: "fetch_failed")
        } else {
          self.pendingFriendKeyChatIdsByUserId.removeValue(forKey: peerId)
        }
      }
    }.resume()
  }

  private func currentUserIdLocked() -> String? {
    normalizedUpper(getConfigValueLocked("userId"))
  }

  private static let decryptFailureLogLock = NSLock()
  private static var decryptFailureLoggedIds: Set<String> = []

  static func noteDecryptFailureOnce(messageId: String) -> Bool {
    cryptoLogOnce("decrypt-failed", messageId: messageId)
  }

  static func cryptoLogOnce(_ event: String, messageId: String) -> Bool {
    guard !messageId.isEmpty else { return false }
    decryptFailureLogLock.lock()
    defer { decryptFailureLogLock.unlock() }
    if decryptFailureLoggedIds.count > 512 { return false }
    return decryptFailureLoggedIds.insert("\(event)|\(messageId)").inserted
  }

  private func decryptPrivateKeyLocked() -> SecKey? {
    guard
      let pem = normalizedString(
        getConfigValueLocked("privateKeyPem") ?? getConfigValueLocked("privateKey"))
    else {
      print("[ChatEngine] decryptPrivateKeyLocked — no privateKeyPem in config")
      return nil
    }
    if let ts = cachedDecryptKeyTimestamp, Date().timeIntervalSince(ts) >= keyTTL {
      cachedDecryptPrivateKey = nil
      cachedDecryptPrivateKeyPem = nil
      cachedDecryptKeyTimestamp = nil
    }
    if cachedDecryptPrivateKeyPem == pem {
      if let cached = cachedDecryptPrivateKey {
        cachedDecryptKeyTimestamp = Date()
        return cached
      }
      if let ts = cachedDecryptKeyTimestamp, Date().timeIntervalSince(ts) < keyTTL {
        return nil
      }
    }
    let key = chatEnginePrivateKey(from: pem)
    if key == nil {
      print(
        "[ChatEngine] decryptPrivateKeyLocked — parsing FAILED, pem.count=\(pem.count) prefix=\(pem.prefix(50))"
      )
    }
    cachedDecryptPrivateKeyPem = pem
    cachedDecryptPrivateKey = key
    cachedDecryptKeyTimestamp = Date()
    VibeCorePrivateKeyBox.shared.publish(key)
    return key
  }

  private func parseLongValue(_ value: Any?) -> Int64? {
    if let n = value as? Int64 { return n }
    if let n = value as? Int { return Int64(n) }
    if let n = value as? Double, n.isFinite { return Int64(n) }
    if let n = value as? Float, n.isFinite { return Int64(n) }
    if let n = value as? NSNumber { return n.int64Value }
    if let s = value as? String { return Int64(s) }
    return nil
  }

  private func parseDoubleValue(_ value: Any?) -> Double? {
    if let n = value as? NSNumber { return n.doubleValue }
    if let s = value as? String { return Double(s) }
    return nil
  }

  private func parseWaveformArray(_ value: Any?) -> [Double]? {
    let rawList: [Any]
    if let array = value as? [Any] {
      rawList = array
    } else if let nsArray = value as? NSArray {
      rawList = nsArray.compactMap { $0 }
    } else {
      return nil
    }
    let mapped = rawList.compactMap { parseDoubleValue($0) }.map { max(0.0, min(1.0, $0)) }
    return mapped.isEmpty ? nil : mapped
  }

  private func deriveFileNameFromURL(_ rawURL: String?) -> String? {
    guard let rawURL = normalizedString(rawURL), !rawURL.isEmpty else { return nil }
    let normalizedPath = rawURL.split(separator: "?", maxSplits: 1).first.map(String.init)
    let name = (normalizedPath ?? rawURL).split(separator: "/").last.map(String.init)
    guard let name else { return nil }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func isLikelyHybridCiphertext(_ raw: String?) -> Bool {
    guard let raw = normalizedString(raw) else { return false }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else {
      return false
    }
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let json = object as? [String: Any]
    else {
      return false
    }
    return json["iv"] != nil && json["c"] != nil && json["k"] != nil
  }

  private func parseDecryptedMessagePayload(_ raw: String) -> [String: Any] {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else {
      return ["text": raw]
    }
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let json = object as? [String: Any]
    else {
      return ["text": raw]
    }
    var out: [String: Any] = [:]
    if let text = json["text"] { out["text"] = text }
    if let mediaUrl = normalizedString(json["mediaUrl"]) {
      out["mediaUrl"] = durableMediaURLStringLocked(mediaUrl)
    }
    if let mediaKey = json["mediaKey"] { out["mediaKey"] = mediaKey }
    if let fileName = json["fileName"] { out["fileName"] = fileName }
    if let fileSize = json["fileSize"] { out["fileSize"] = fileSize }
    if let latitude = json["latitude"] { out["latitude"] = latitude }
    if let longitude = json["longitude"] { out["longitude"] = longitude }
    if let duration = json["duration"] { out["duration"] = duration }
    if let replyToId = json["replyToId"] { out["replyToId"] = replyToId }
    if let replyPreview = json["replyPreview"] ?? json["reply_preview"] {
      out["replyPreview"] = replyPreview
    }
    if let replyPreviewTitle =
      json["replyPreviewTitle"] ?? json["reply_preview_title"] ?? json["replyAuthorName"]
      ?? json["reply_author_name"]
    {
      out["replyPreviewTitle"] = replyPreviewTitle
    }
    if let replyPreviewText =
      json["replyPreviewText"] ?? json["reply_preview_text"] ?? json["replyText"]
      ?? json["reply_text"]
    {
      out["replyPreviewText"] = replyPreviewText
    }
    if let contact = json["contact"] { out["contact"] = contact }
    if let caption = json["caption"] { out["caption"] = caption }
    if let viewOnce = json["viewOnce"] { out["viewOnce"] = viewOnce }
    if let mediaTtlSeconds = json["mediaTtlSeconds"] ?? json["media_ttl_seconds"] {
      out["mediaTtlSeconds"] = mediaTtlSeconds
    }
    if let isEdited = json["isEdited"] { out["isEdited"] = isEdited }
    if let editedAt = json["editedAt"] { out["editedAt"] = editedAt }
    if let waveform = json["waveform"] { out["waveform"] = waveform }
    if let isVideoNote = json["isVideoNote"] { out["isVideoNote"] = isVideoNote }
    if let width = json["width"] { out["width"] = width }
    if let height = json["height"] { out["height"] = height }
    if let thumbnailBase64 = json["thumbnailBase64"] { out["thumbnailBase64"] = thumbnailBase64 }
    if let stickerId = json["stickerId"] { out["stickerId"] = stickerId }
    if let stickerPackId = json["stickerPackId"] ?? json["packId"] {
      out["stickerPackId"] = stickerPackId
    }
    if let stickerBundleFileName = json["stickerBundleFileName"] ?? json["bundleFileName"] {
      out["stickerBundleFileName"] = stickerBundleFileName
    }
    if let emoji = json["emoji"] { out["emoji"] = emoji }
    if out.isEmpty {
      out["text"] = raw
    }
    return out
  }

  private func formatMessageTimeLabel(timestampMs: Int64) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0))
  }

  private func messageId(fromRow row: [String: Any]) -> String? {
    guard normalizedString(row["kind"]) == "message",
      let message = row["message"] as? [String: Any]
    else {
      return nil
    }
    return normalizedString(message["id"])
  }

  private func messageIsMe(fromRow row: [String: Any]) -> Bool {
    guard let message = row["message"] as? [String: Any] else { return false }
    return (message["isMe"] as? Bool) == true
  }

  private func messageTimestampMs(fromRow row: [String: Any]) -> Int64 {
    guard let message = row["message"] as? [String: Any] else { return 0 }
    return transcriptTimestampMs(message) ?? 0
  }

  func transcriptTimestampMs(_ message: [String: Any]) -> Int64? {
    for key in ["timestampMs", "timestamp_ms", "timestamp"] {
      if let value = message[key], !(value is NSNull), let parsed = parseLongValue(value) {
        return parsed
      }
    }
    return nil
  }

  private static var transcriptTimestampSynthesizedCount = 0

  private func noteSynthesizedTimestamp(chatId: String, messageId: String, raw: [String: Any]) {
    Self.transcriptTimestampSynthesizedCount &+= 1
    let present =
      ["timestampMs", "timestamp_ms", "timestamp"]
      .compactMap { key -> String? in
        guard let value = raw[key], !(value is NSNull) else { return nil }
        return "\(key):\(type(of: value))"
      }
      .joined(separator: ",")
    VibeLog.warning(
      "message has no readable timestamp — ordered by this device's clock",
      category: "order",
      metadata: [
        "chat": String(chatId.prefix(12)),
        "message": String(messageId.prefix(12)),
        "carried": present.isEmpty ? "none" : present,
        "totalThisLaunch": String(Self.transcriptTimestampSynthesizedCount),
      ])
  }

  func logTranscriptOrderFingerprint(chatId: String, rows: [[String: Any]], reason: String) {
    guard !rows.isEmpty else { return }
    var hasher = Hasher()
    var inversions = 0
    var previousTs: Int64 = .min
    for row in rows {
      let id = messageId(fromRow: row) ?? ""
      let ts = messageTimestampMs(fromRow: row)
      hasher.combine(id)
      hasher.combine(ts)
      if ts < previousTs { inversions += 1 }
      previousTs = ts
    }
    let tail = rows.suffix(12).map { row in
      "\(messageTimestampMs(fromRow: row)):\(String((messageId(fromRow: row) ?? "?").prefix(8)))"
    }
    VibeLog.notice(
      "transcript order chat=\(String(chatId.prefix(12))) rows=\(rows.count) "
        + "digest=\(String(format: "%016llx", UInt64(bitPattern: Int64(hasher.finalize()))))"
        + (inversions > 0 ? " INVERSIONS=\(inversions)" : ""),
      category: "order",
      metadata: [
        "chat": String(chatId.prefix(12)),
        "rows": String(rows.count),
        "reason": reason,
        "inversions": String(inversions),
        "tail": tail.joined(separator: " "),
      ])
  }

  func rawMessageIdForOrdering(_ raw: [String: Any], chatId: String) -> String? {
    let preferred =
      chatId == "saved_messages"
      ? raw["original_message_id"] ?? raw["originalMessageId"] ?? raw["id"] ?? raw["message_id"]
      : raw["id"] ?? raw["message_id"]
    return normalizedString(preferred)
  }

  func transcriptOrderPrecedes(
    lhsTs: Int64?, lhsId: String?, rhsTs: Int64?, rhsId: String?
  ) -> Bool {
    let lt = lhsTs ?? 0
    let rt = rhsTs ?? 0
    if lt != rt { return lt < rt }
    return (lhsId ?? "") < (rhsId ?? "")
  }

  private func bubbleShapePayload(
    isMe: Bool,
    isSequenceStart: Bool,
    isSequenceEnd: Bool
  ) -> [String: Any] {
    let full: CGFloat = 18
    let merged: CGFloat = 12
    var shape: [String: Any] = [
      "isMe": isMe,
      "showTail": isSequenceEnd,
      "borderTopLeftRadius": full,
      "borderTopRightRadius": full,
      "borderBottomLeftRadius": full,
      "borderBottomRightRadius": full,
    ]

    if isMe {
      shape["borderTopRightRadius"] = full
      shape["borderBottomRightRadius"] = isSequenceEnd ? full : merged
    } else {
      shape["borderTopLeftRadius"] = isSequenceStart ? full : merged
      shape["borderBottomLeftRadius"] = isSequenceEnd ? full : merged
    }

    return shape
  }

  private func rowsByApplyingBubbleSequenceShapes(_ rows: [[String: Any]]) -> [[String: Any]] {
    var patchedRows = rows
    let messageIndices = rows.indices.filter { messageId(fromRow: rows[$0]) != nil }
    guard !messageIndices.isEmpty else { return rows }

    for (offset, rowIndex) in messageIndices.enumerated() {
      guard var message = patchedRows[rowIndex]["message"] as? [String: Any] else { continue }
      let isMe = messageIsMe(fromRow: rows[rowIndex])
      let previousIsSameSender: Bool = {
        guard offset > 0 else { return false }
        return messageIsMe(fromRow: rows[messageIndices[offset - 1]]) == isMe
      }()
      let nextIsSameSender: Bool = {
        guard offset + 1 < messageIndices.count else { return false }
        return messageIsMe(fromRow: rows[messageIndices[offset + 1]]) == isMe
      }()
      message["bubbleShape"] = bubbleShapePayload(
        isMe: isMe,
        isSequenceStart: !previousIsSameSender,
        isSequenceEnd: !nextIsSameSender
      )
      patchedRows[rowIndex]["message"] = message
    }

    return patchedRows
  }

  /// Display fields a live socket frame may omit; dropping them re-measures a settled row.
  private static let liveRowFieldsRestoredFromHistory = [
    "isAgentMessage", "agentName", "agentId", "agentUserId", "agentUsername",
    "plainContent", "text", "type",
    "replyToId", "replyPreviewTitle", "replyPreviewText", "replyPreview",
  ]

  private func liveRowPreservingAgentIdentityLocked(
    live: [String: Any], history: [String: Any], messageId: String
  ) -> [String: Any] {
    guard var liveMessage = live["message"] as? [String: Any],
      let historyMessage = history["message"] as? [String: Any]
    else { return live }
    // A live frame is an update, not a replacement: a key it does not carry must not erase
    // the settled row, or the bubble re-measures and the list shifts under the reader.
    var restoredKeys: [String] = []
    for key in Self.liveRowFieldsRestoredFromHistory
    where liveMessage[key] == nil || liveMessage[key] is NSNull {
      guard let value = historyMessage[key], !(value is NSNull) else { continue }
      liveMessage[key] = value
      restoredKeys.append(key)
    }
    if (historyMessage["isAgentMessage"] as? Bool) == true,
      (liveMessage["isAgentMessage"] as? Bool) != true
    {
      liveMessage["isAgentMessage"] = true
      restoredKeys.append("isAgentMessage")
    }
    guard !restoredKeys.isEmpty else { return live }
    NSLog(
      "[AgentDowngrade] live row dropped settled fields id=%@ restored=%@",
      String(messageId.suffix(12)), restoredKeys.prefix(8).joined(separator: ","))
    var restored = live
    restored["message"] = liveMessage
    return restored
  }

  private func mergedChatRowsLocked(chatId: String) -> [[String: Any]] {
    let historyRows = historyRowsByChat[chatId] ?? []
    let liveRows = liveMessageRowsByChat[chatId] ?? [:]
    let deletedIds = deletedMessageIdsByChat[chatId] ?? []
    guard !historyRows.isEmpty || !liveRows.isEmpty else { return [] }

    var mergedById: [String: [String: Any]] = [:]
    var rowsWithoutIds: [[String: Any]] = []
    for row in historyRows {
      guard let messageId = messageId(fromRow: row) else {
        rowsWithoutIds.append(row)
        continue
      }
      guard !deletedIds.contains(messageId) else { continue }
      let chosen: [String: Any]
      if let live = liveRows[messageId] {
        chosen = liveRowPreservingAgentIdentityLocked(
          live: live, history: row, messageId: messageId)
      } else {
        chosen = row
      }
      mergedById[messageId] = rowAdoptingSettleSlotTs(chosen, messageId: messageId)
    }

    for (messageId, row) in liveRows {
      guard !deletedIds.contains(messageId), mergedById[messageId] == nil else { continue }
      mergedById[messageId] = rowAdoptingSettleSlotTs(row, messageId: messageId)
    }

    let ownUserTexts: [(text: String, ts: Int64)] = mergedById.compactMap { id, row in
      guard !id.hasPrefix("bridge-"), !id.hasPrefix("stream-"),
        messageIsMe(fromRow: row),
        let message = row["message"] as? [String: Any],
        let text = normalizedString(message["text"])?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !text.isEmpty
      else { return nil }
      return (text, messageTimestampMs(fromRow: row))
    }
    if !ownUserTexts.isEmpty {
      let mirrorDedupWindowMs = Self.bridgeMirrorDedupWindowMs
      for (id, row) in mergedById {
        guard id.hasPrefix("bridge-"), messageIsMe(fromRow: row),
          let message = row["message"] as? [String: Any],
          let rawText = normalizedString(message["text"])
        else { continue }
        let text = Self.bridgeMirrorComparableText(rawText)
        guard !text.isEmpty else { continue }
        let ts = messageTimestampMs(fromRow: row)
        if ownUserTexts.contains(where: { $0.text == text && abs($0.ts - ts) <= mirrorDedupWindowMs }) {
          mergedById.removeValue(forKey: id)
        }
      }
    }

    let persistedAgentResponses: [(text: String, from: String, ts: Int64)] =
      mergedById.compactMap { id, row in
        guard !id.hasPrefix("bridge-"), !id.hasPrefix("stream-"),
          let message = row["message"] as? [String: Any],
          (message["isAgentMessage"] as? Bool) == true,
          let text = normalizedString(message["plainContent"] ?? message["text"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty
        else { return nil }
        return (
          text,
          normalizedUpper(message["agentUserId"] ?? message["fromId"]) ?? "",
          messageTimestampMs(fromRow: row)
        )
      }
    if !persistedAgentResponses.isEmpty {
      let mirrorWindowMs: Int64 = 5 * 60 * 1000
      for (id, row) in mergedById where id.hasPrefix("bridge-") {
        guard let message = row["message"] as? [String: Any],
          (message["isAgentMessage"] as? Bool) == true,
          let text = normalizedString(message["plainContent"] ?? message["text"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty
        else { continue }
        let from = normalizedUpper(message["agentUserId"] ?? message["fromId"]) ?? ""
        let ts = messageTimestampMs(fromRow: row)
        if persistedAgentResponses.contains(where: {
          $0.text == text && ($0.from.isEmpty || from.isEmpty || $0.from == from)
            && abs($0.ts - ts) <= mirrorWindowMs
        }) {
          mergedById.removeValue(forKey: id)
        }
      }
    }

    let hasFinishedAgentCard = mergedById.contains { id, row in
      guard id.hasPrefix("bridge-") else { return false }
      guard let message = row["message"] as? [String: Any] else { return false }
      guard (message["isAgentMessage"] as? Bool) == true else { return false }
      let meta = message["metadata"] as? [String: Any]
      let streaming =
        (message["isStreaming"] as? Bool) == true || (meta?["isStreaming"] as? Bool) == true
      return !streaming
    }
    for (id, row) in mergedById {
      guard let message = row["message"] as? [String: Any] else { continue }
      let isAgent = (message["isAgentMessage"] as? Bool) == true
      guard isAgent else { continue }
      let meta = message["metadata"] as? [String: Any]
      let streaming =
        (message["isStreaming"] as? Bool) == true || (meta?["isStreaming"] as? Bool) == true
      let text = (
        normalizedString(message["plainContent"])
          ?? normalizedString(message["text"])
          ?? ""
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      let nodes =
        (meta?["progressNodes"] as? [[String: Any]])
        ?? (message["progressNodes"] as? [[String: Any]])
        ?? []
      let hasNodes = !nodes.isEmpty
      let onlyPlaceholderThinking = hasNodes && nodes.allSatisfy { node in
        let kind = (normalizedString(node["kind"] ?? node["itemType"]) ?? "").lowercased()
        let label = (normalizedString(node["label"] ?? node["title"]) ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let detail = (
          normalizedString(node["detail"] ?? node["messageContent"] ?? node["messagePreview"]) ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind == "thinking" || label == "thinking" || label == "thinking..." else {
          return false
        }
        return detail.isEmpty
      }
      if text.isEmpty, (!hasNodes || onlyPlaceholderThinking) {
        mergedById.removeValue(forKey: id)
        VibeDebugLog.log(
          "[EmptyTrace] dropEmptyAgentShell id=%@ chat=%@ streaming=%@ nodes=%d placeholder=%@",
          String(id.suffix(20)), String(chatId.suffix(12)),
          streaming ? "Y" : "N", nodes.count, onlyPlaceholderThinking ? "Y" : "N")
        continue
      }
      if id.hasPrefix("stream-"), hasFinishedAgentCard {
        mergedById.removeValue(forKey: id)
        VibeDebugLog.log(
          "[EmptyTrace] dropStaleStreamRow id=%@ chat=%@ textLen=%d nodes=%d streaming=%@",
          String(id.suffix(20)), String(chatId.suffix(12)), text.count, nodes.count,
          streaming ? "Y" : "N")
        continue
      }
      if id.contains("running-mirror"), text.isEmpty, hasFinishedAgentCard || !streaming {
        mergedById.removeValue(forKey: id)
        continue
      }
    }

    let staleStreamingIds: [String] = mergedById.compactMap { id, row in
      let minStaleMs: Int64 = liveRows[id] == nil ? (3 * 60 * 1000) : (60 * 60 * 1000)
      return isStaleStreamingAgentRowLocked(row, minStaleMs: minStaleMs) ? id : nil
    }
    for id in staleStreamingIds {
      guard let row = mergedById[id] else { continue }
      mergedById[id] = terminalizedStaleAgentRowLocked(row)
      NSLog(
        "[TeamSettle] merge-coerce chat=%@ id=%@ inLiveStore=%@",
        String(chatId.suffix(12)), String(id.suffix(12)),
        liveRows[id] != nil ? "Y" : "N")
    }

    var mergedRows = Array(mergedById.values)
    mergedRows.sort { lhs, rhs in
      transcriptOrderPrecedes(
        lhsTs: messageTimestampMs(fromRow: lhs), lhsId: messageId(fromRow: lhs),
        rhsTs: messageTimestampMs(fromRow: rhs), rhsId: messageId(fromRow: rhs))
    }
    mergedRows.insert(contentsOf: rowsWithoutIds, at: 0)
    return rowsByApplyingBubbleSequenceShapes(mergedRows)
  }

  private func ingestHistoryRowsLocked(
    chatId: String,
    remoteRows: [[String: Any]]
  ) -> (rows: [[String: Any]], delta: ChatIngestDelta) {
    let existingRows = historyRowsByChat[chatId] ?? []
    let deletedIds = deletedMessageIdsByChat[chatId] ?? []
    guard !existingRows.isEmpty || !remoteRows.isEmpty else {
      return (
        [],
        ChatIngestDelta(insertedIds: [], updatedIds: [], deletedIds: []))
    }

    var mergedById: [String: [String: Any]] = [:]
    var rowsWithoutIds: [[String: Any]] = []
    for row in existingRows {
      guard let messageId = messageId(fromRow: row) else {
        rowsWithoutIds.append(row)
        continue
      }
      guard !deletedIds.contains(messageId) else { continue }
      mergedById[messageId] = rowAdoptingSettleSlotTs(row, messageId: messageId)
    }

    for row in remoteRows {
      guard let messageId = messageId(fromRow: row) else {
        rowsWithoutIds.append(row)
        continue
      }
      guard !deletedIds.contains(messageId) else { continue }
      var mergedRow = row
      if let existing = mergedById[messageId] {
        if mergedRow["message"] is [String: Any] || existing["message"] is [String: Any] {
          var mergedMessage = mergedRow["message"] as? [String: Any] ?? [:]
          let existingMessage = existing["message"] as? [String: Any] ?? [:]
          for (key, value) in existingMessage
          where mergedMessage[key] == nil || mergedMessage[key] is NSNull {
            if Self.ingestTransientMessageKeys.contains(key) { continue }
            if key == "metadata", var carriedMeta = value as? [String: Any] {
              carriedMeta.removeValue(forKey: "isStreaming")
              carriedMeta.removeValue(forKey: "is_streaming")
              mergedMessage[key] = carriedMeta
              continue
            }
            mergedMessage[key] = value
          }
          if let existingMeta = existingMessage["metadata"] as? [String: Any] {
            let localVersion =
              (existingMeta["agentTurnStructureVersion"] as? Int)
              ?? (existingMeta["agentTurnStructureVersion"] as? NSNumber)?.intValue
              ?? 0
            if localVersion >= 2,
              let localNodes = existingMeta["progressNodes"] as? [[String: Any]],
              !localNodes.isEmpty
            {
              var meta = mergedMessage["metadata"] as? [String: Any] ?? [:]
              let remoteNodes = (meta["progressNodes"] as? [[String: Any]]) ?? []
              if remoteNodes.count < localNodes.count || meta["agentTurnStructureVersion"] == nil {
                meta["progressNodes"] = localNodes
                meta["agentTurnStructureVersion"] = localVersion
                mergedMessage["metadata"] = meta
              }
            }
            var meta = mergedMessage["metadata"] as? [String: Any] ?? [:]
            var carriedAttachment = false
            for key in Self.ingestDurableAttachmentKeys
            where meta[key] == nil || meta[key] is NSNull {
              guard let value = existingMeta[key] else { continue }
              meta[key] = value
              carriedAttachment = true
            }
            if carriedAttachment { mergedMessage["metadata"] = meta }
          }
          mergedRow["message"] = mergedMessage
        }
        for (key, value) in existing
        where key != "message" && (mergedRow[key] == nil || mergedRow[key] is NSNull) {
          mergedRow[key] = value
        }
      }
      mergedById[messageId] = rowAdoptingSettleSlotTs(mergedRow, messageId: messageId)
    }

    var mergedRows = Array(mergedById.values)
    mergedRows.sort { lhs, rhs in
      transcriptOrderPrecedes(
        lhsTs: messageTimestampMs(fromRow: lhs), lhsId: messageId(fromRow: lhs),
        rhsTs: messageTimestampMs(fromRow: rhs), rhsId: messageId(fromRow: rhs))
    }
    mergedRows.insert(contentsOf: rowsWithoutIds, at: 0)
    let rows = rowsByApplyingBubbleSequenceShapes(mergedRows)
    logTranscriptOrderFingerprint(chatId: chatId, rows: rows, reason: "ingest")

    var previousRowsById: [String: [String: Any]] = [:]
    for row in existingRows {
      guard let messageId = messageId(fromRow: row) else { continue }
      previousRowsById[messageId] = row
    }
    var rowsById: [String: [String: Any]] = [:]
    for row in rows {
      guard let messageId = messageId(fromRow: row) else { continue }
      rowsById[messageId] = row
    }

    let previousIds = Set(previousRowsById.keys)
    let ids = Set(rowsById.keys)
    let insertedIds = ids.subtracting(previousIds).sorted()
    let deltaDeletedIds = previousIds.subtracting(ids).sorted()
    let updatedIds = ids.intersection(previousIds).filter { messageId in
      guard let row = rowsById[messageId], let previousRow = previousRowsById[messageId] else {
        return false
      }
      return !(row as NSDictionary).isEqual(to: previousRow)
    }.sorted()
    return (
      rows,
      ChatIngestDelta(
        insertedIds: insertedIds,
        updatedIds: updatedIds,
        deletedIds: deltaDeletedIds))
  }

  private func mergedStoredHistoryRowsLocked(
    chatId: String,
    remoteRows: [[String: Any]]
  ) -> [[String: Any]] {
    ingestHistoryRowsLocked(chatId: chatId, remoteRows: remoteRows).rows
  }

  private func storeMergedChatHistoryIfLoadedLocked(chatId: String) {
    let rows = mergedChatRowsLocked(chatId: chatId).filter { !isTransientStreamRow($0) }
    guard !rows.isEmpty else { return }
    storeCachedHistoryRowsLocked(chatId: chatId, rows: rows)
  }

  @discardableResult
  private func upsertLiveMessageRowLocked(
    chatId: String, messageId: String, row: [String: Any]
  ) -> Bool {
    let wasPresent =
      liveMessageRowsByChat[chatId]?[messageId] != nil
      || (historyRowsByChat[chatId] ?? []).contains {
        self.messageId(fromRow: $0) == messageId
      }
    var perChat = liveMessageRowsByChat[chatId] ?? [:]
    perChat[messageId] = row
    liveMessageRowsByChat[chatId] = perChat
    if var deleted = deletedMessageIdsByChat[chatId] {
      deleted.remove(messageId)
      if deleted.isEmpty {
        deletedMessageIdsByChat.removeValue(forKey: chatId)
      } else {
        deletedMessageIdsByChat[chatId] = deleted
      }
    }
    storeMergedChatHistoryIfLoadedLocked(chatId: chatId)
    return !wasPresent
  }

  @discardableResult
  private func mutateLiveMessagePayloadLocked(
    chatId: String,
    messageId: String,
    mutate: (inout [String: Any]) -> Void
  ) -> Bool {
    guard var perChat = liveMessageRowsByChat[chatId],
      var row = perChat[messageId],
      var message = row["message"] as? [String: Any]
    else {
      return false
    }
    let previousMessage = message
    mutate(&message)
    guard !(message as NSDictionary).isEqual(to: previousMessage) else { return false }
    row["message"] = message
    perChat[messageId] = row
    liveMessageRowsByChat[chatId] = perChat
    return true
  }

  @discardableResult
  private func settleLiveBridgeMessageLocked(
    chatId: String,
    messageId: String,
    terminalStatus: String
  ) -> Bool {
    guard var perChat = liveMessageRowsByChat[chatId],
      var row = perChat[messageId],
      var message = row["message"] as? [String: Any]
    else { return false }

    var metadata = (message["metadata"] as? [String: Any]) ?? [:]
    var runtime = (metadata["agentRuntime"] as? [String: Any]) ?? [:]
    let activeStates = Set(["running", "starting", "pending", "active", "streaming"])
    let previousRuntimeStatus = (normalizedString(runtime["status"]) ?? "").lowercased()
    let wasLive =
      (message["isStreaming"] as? Bool) == true
      || (metadata["isStreaming"] as? Bool) == true
      || activeStates.contains(previousRuntimeStatus)
      || ((runtime["teamWorkersStatus"] as? [[String: Any]]) ?? []).contains { worker in
        activeStates.contains((normalizedString(worker["status"]) ?? "").lowercased())
      }
    guard wasLive else { return false }

    func terminalized(_ entries: [[String: Any]]) -> [[String: Any]] {
      entries.map { entry in
        var next = entry
        let state = (normalizedString(next["status"]) ?? "").lowercased()
        if activeStates.contains(state) {
          next["status"] = terminalStatus
        }
        return next
      }
    }

    message["isStreaming"] = false
    metadata["isStreaming"] = false
    runtime["status"] = terminalStatus
    runtime["controls"] = ["canCancel": false, "canRevert": false]

    let workerRows =
      (runtime["teamWorkersStatus"] as? [[String: Any]])
      ?? (metadata["teamWorkersStatus"] as? [[String: Any]])
      ?? []
    if !workerRows.isEmpty {
      let settledWorkers = terminalized(workerRows)
      runtime["teamWorkersStatus"] = settledWorkers
      metadata["teamWorkersStatus"] = settledWorkers
    }
    if let nodes = metadata["progressNodes"] as? [[String: Any]], !nodes.isEmpty {
      metadata["progressNodes"] = terminalized(nodes)
    }
    metadata["agentRuntime"] = runtime
    message["metadata"] = metadata
    row["message"] = message
    perChat[messageId] = row
    liveMessageRowsByChat[chatId] = perChat
    return true
  }

  private func isStaleStreamingAgentRowLocked(_ row: [String: Any], minStaleMs: Int64) -> Bool {
    guard let message = row["message"] as? [String: Any] else { return false }
    let meta = message["metadata"] as? [String: Any]
    let isAgentRow =
      (message["isAgentMessage"] as? Bool) == true
      || meta?["agentRuntime"] != nil || meta?["agent_runtime"] != nil
      || message["agentRuntime"] != nil || message["agent_runtime"] != nil
      || meta?["agentRuntimeEnc"] != nil || meta?["agent_runtime_enc"] != nil
      || message["agentRuntimeEnc"] != nil || message["agent_runtime_enc"] != nil
      || meta?["teamWorkersStatus"] != nil || meta?["team_workers_status"] != nil
      || (meta?["progressNodes"] as? [[String: Any]])?.isEmpty == false
      || (message["progressNodes"] as? [[String: Any]])?.isEmpty == false
      || normalizedString(message["agentUserId"] ?? message["agent_user_id"]) != nil
      || normalizedString(message["agentUsername"] ?? message["agent_username"]) != nil
    guard isAgentRow else { return false }
    let active = Set(["running", "starting", "pending", "queued", "active", "streaming", "waiting"])
    let runtime = meta?["agentRuntime"] as? [String: Any]
    let streaming =
      (message["isStreaming"] as? Bool) == true
      || (meta?["isStreaming"] as? Bool) == true
      || active.contains((normalizedString(runtime?["status"]) ?? "").lowercased())
      || ((runtime?["teamWorkersStatus"] as? [[String: Any]]) ?? []).contains { worker in
        active.contains((normalizedString(worker["status"]) ?? "").lowercased())
      }
    guard streaming else { return false }
    let ts = messageTimestampMs(fromRow: row)
    return ts == 0 || Int64(nowMs()) - ts > minStaleMs
  }

  private func terminalizedStaleAgentRowLocked(_ row: [String: Any]) -> [String: Any] {
    guard var message = row["message"] as? [String: Any] else { return row }
    let activeStates = Set(["running", "starting", "pending", "queued", "active", "streaming", "waiting"])
    func terminalized(_ entries: [[String: Any]]) -> [[String: Any]] {
      entries.map { entry in
        var next = entry
        let state = (normalizedString(next["status"]) ?? "").lowercased()
        if activeStates.contains(state) { next["status"] = "stopped" }
        return next
      }
    }
    var metadata = (message["metadata"] as? [String: Any]) ?? [:]
    var runtime = (metadata["agentRuntime"] as? [String: Any]) ?? [:]
    message["isStreaming"] = false
    metadata["isStreaming"] = false
    runtime["status"] = "stopped"
    runtime["controls"] = ["canCancel": false, "canRevert": false]
    if let workers = runtime["teamWorkersStatus"] as? [[String: Any]], !workers.isEmpty {
      runtime["teamWorkersStatus"] = terminalized(workers)
    }
    if let workers = metadata["teamWorkersStatus"] as? [[String: Any]], !workers.isEmpty {
      metadata["teamWorkersStatus"] = terminalized(workers)
    }
    if let nodes = metadata["progressNodes"] as? [[String: Any]], !nodes.isEmpty {
      metadata["progressNodes"] = terminalized(nodes)
    }
    metadata["agentRuntime"] = runtime
    message["metadata"] = metadata
    var out = row
    out["message"] = message
    return out
  }

  private func markAgentTaskRetiredLocked(chatId: String, taskId: String) {
    let id = taskId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty, !id.isEmpty else { return }
    let now = Int64(nowMs())
    var perChat = retiredAgentTaskIdsByChatId[chatId] ?? [:]
    perChat[id] = now
    perChat = perChat.filter { now - $0.value < Self.retiredAgentTaskTtlMs }
    if perChat.count > 64 {
      let newest = perChat.sorted { $0.value > $1.value }.prefix(64)
      perChat = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }
    retiredAgentTaskIdsByChatId[chatId] = perChat
  }

  private func isAgentTaskRetiredLocked(chatId: String, taskId: String) -> Bool {
    guard let retiredAt = retiredAgentTaskIdsByChatId[chatId]?[taskId] else { return false }
    return Int64(nowMs()) - retiredAt < Self.retiredAgentTaskTtlMs
  }

  private func removeBridgeTaskTrackingLocked(chatId: String, taskId: String) {
    let taskKey = "\(chatId):\(taskId)"
    markAgentTaskRetiredLocked(chatId: chatId, taskId: taskId)
    cloudProgressAtMsByTask.removeValue(forKey: taskKey)
    if var taskRows = liveStreamTaskRowIdByChatId[chatId] {
      taskRows.removeValue(forKey: taskId)
      if taskRows.isEmpty {
        liveStreamTaskRowIdByChatId.removeValue(forKey: chatId)
      } else {
        liveStreamTaskRowIdByChatId[chatId] = taskRows
      }
    }
    let lanKeys = lanProgressLinesByTask.keys.filter { $0.contains(":\(chatId):\(taskId)") }
    for key in lanKeys {
      lanProgressLinesByTask.removeValue(forKey: key)
      lanProgressSeqByTask.removeValue(forKey: key)
    }
  }

  private func settleAgentBridgeTaskLocked(
    chatId: String,
    taskId: String,
    terminalStatus: String,
    reason: String
  ) {
    let matchingIds = (liveMessageRowsByChat[chatId] ?? [:]).compactMap {
      messageId, row -> String? in
      guard let message = row["message"] as? [String: Any],
        let metadata = message["metadata"] as? [String: Any]
      else { return nil }
      let runtime = (metadata["agentRuntime"] as? [String: Any]) ?? [:]
      let rowTaskId = normalizedString(
        runtime["taskId"] ?? runtime["task_id"]
          ?? metadata["agentTaskId"] ?? metadata["agent_task_id"])
      return rowTaskId == taskId ? messageId : nil
    }
    var changedIds: [String] = []
    for messageId in matchingIds {
      if settleLiveBridgeMessageLocked(
        chatId: chatId,
        messageId: messageId,
        terminalStatus: terminalStatus
      ) {
        changedIds.append(messageId)
      }
    }
    removeBridgeTaskTrackingLocked(chatId: chatId, taskId: taskId)
    guard !changedIds.isEmpty else { return }
    agentTurnRunningAtMsByChatId.removeValue(forKey: chatId)
    clearAgentProgressLocked(chatId: chatId, status: terminalStatus, reason: reason)
    storeMergedChatHistoryIfLoadedLocked(chatId: chatId)
    postChangeLocked(
      reason: "chatRowsReloaded",
      userInfo: ["chatId": chatId, "state": statusSnapshotLocked()]
    )
    postChatDeltaLocked(
      chatId: chatId, inserted: [], updated: changedIds, deleted: [], source: "bridgeSettle")
  }

  private func setLiveMessageStatusLocked(chatId: String, messageId: String, status: String) -> Bool {
    mutateLiveMessagePayloadLocked(chatId: chatId, messageId: messageId) { message in
      message["status"] = status
    }
  }

  // MARK: - Bridge tail-cell liveness (mid-run collapse fix)

  private func bridgeMarkSessionSettledLocked(chatId: String, sessionId: String, contentSig: String) {
    guard !sessionId.isEmpty else { return }
    var perChat = bridgeSettledSessionSigByChatId[chatId] ?? [:]
    perChat[sessionId] = contentSig
    if perChat.count > 24 { perChat = [sessionId: contentSig] }
    bridgeSettledSessionSigByChatId[chatId] = perChat
  }

  private func bridgeClearSessionSettledLocked(chatId: String, sessionId: String) {
    guard var perChat = bridgeSettledSessionSigByChatId[chatId], perChat[sessionId] != nil else {
      return
    }
    perChat.removeValue(forKey: sessionId)
    if perChat.isEmpty {
      bridgeSettledSessionSigByChatId.removeValue(forKey: chatId)
    } else {
      bridgeSettledSessionSigByChatId[chatId] = perChat
    }
  }

  private func bridgeSessionIsSettledLocked(chatId: String, sessionId: String) -> Bool {
    bridgeSettledSessionSigByChatId[chatId]?[sessionId] != nil
  }

  private func bridgeRunIsLiveLocked(chatId: String, sessionId: String) -> Bool {
    if bridgeSessionIsSettledLocked(chatId: chatId, sessionId: sessionId) { return false }
    let askOutstanding = agentBridgeAskByRequestId.values.contains { payload in
      (normalizedString(payload["chatId"]) ?? "") == chatId
    }
    if askOutstanding { return true }
    guard let last = agentTurnRunningAtMsByChatId[chatId] else { return false }
    return Int64(nowMs()) - last < Self.agentTurnRunningGraceMs
  }

  private func settleBridgeTailRowStreamingLocked(chatId: String, sessionId: String, uid: String) {
    guard !uid.isEmpty else { return }
    let messageId = "bridge-\(sessionId)-\(uid)"
    var changed = false
    mutateLiveMessagePayloadLocked(chatId: chatId, messageId: messageId) { message in
      let wasStreaming =
        (message["isStreaming"] as? Bool) == true
        || ((message["metadata"] as? [String: Any])?["isStreaming"] as? Bool) == true
      guard wasStreaming else { return }
      message["isStreaming"] = false
      var metadata = (message["metadata"] as? [String: Any]) ?? [:]
      metadata["isStreaming"] = false
      message["metadata"] = metadata
      changed = true
    }
    guard changed else { return }
    storeMergedChatHistoryIfLoadedLocked(chatId: chatId)
    postChangeLocked(
      reason: "chatMessageChanged",
      userInfo: ["chatId": chatId, "messageId": messageId, "state": statusSnapshotLocked()]
    )
    postChatDeltaLocked(
      chatId: chatId, inserted: [], updated: [messageId], deleted: [], source: "bridgeSettle")
  }

  private func adoptAgentSettleSlotTsLocked(chatId: String, messageId: String, slotTs: Int64) {
    guard slotTs > 0 else { return }
    if agentSettleSlotTsByMessageId[messageId] == nil {
      agentSettleSlotTsOrder.append(messageId)
      if agentSettleSlotTsOrder.count > 256 {
        let evicted = agentSettleSlotTsOrder.removeFirst()
        agentSettleSlotTsByMessageId.removeValue(forKey: evicted)
      }
    }
    agentSettleSlotTsByMessageId[messageId] = slotTs
    mutateLiveMessagePayloadLocked(chatId: chatId, messageId: messageId) { message in
      message["timestampMs"] = slotTs
      message["timestamp"] = slotTs
    }
    NSLog(
      "[AgentOrder] settle adopts live slot chatId=%@ messageId=%@ slotTs=%lld",
      String(chatId.suffix(12)), String(messageId.suffix(12)), slotTs)
  }

  private func rowAdoptingSettleSlotTs(_ row: [String: Any], messageId: String) -> [String: Any] {
    guard let slotTs = agentSettleSlotTsByMessageId[messageId],
      var message = row["message"] as? [String: Any]
    else { return row }
    let current =
      parseLongValue(message["timestampMs"] ?? message["timestamp_ms"] ?? message["timestamp"])
      ?? 0
    guard current != slotTs else { return row }
    message["timestampMs"] = slotTs
    message["timestamp"] = slotTs
    message.removeValue(forKey: "timestamp_ms")
    var next = row
    next["message"] = message
    return next
  }

  @discardableResult
  private func setLiveMessageUploadProgressLocked(
    chatId: String,
    messageId: String,
    progress: Double?,
    postDelta: Bool = true
  ) -> Bool {
    let normalizedProgress: Double?
    if let progress, progress.isFinite {
      normalizedProgress = max(0.0, min(1.0, progress))
    } else {
      normalizedProgress = nil
    }

    let existingProgress: Double? = {
      guard let perChat = liveMessageRowsByChat[chatId],
        let row = perChat[messageId],
        let message = row["message"] as? [String: Any]
      else {
        return nil
      }
      return parseDoubleValue(message["uploadProgress"])
        ?? parseDoubleValue((message["metadata"] as? [String: Any])?["uploadProgress"])
    }()

    let isUnchanged: Bool = {
      switch (existingProgress, normalizedProgress) {
      case (nil, nil):
        return true
      case let (lhs?, rhs?):
        return abs(lhs - rhs) < 0.004
      default:
        return false
      }
    }()
    if isUnchanged {
      return false
    }

    let changed = mutateLiveMessagePayloadLocked(chatId: chatId, messageId: messageId) { message in
      if let clamped = normalizedProgress {
        message["uploadProgress"] = clamped
        var metadata = (message["metadata"] as? [String: Any]) ?? [:]
        metadata["uploadProgress"] = clamped
        message["metadata"] = metadata
      } else {
        message.removeValue(forKey: "uploadProgress")
        if var metadata = message["metadata"] as? [String: Any] {
          metadata.removeValue(forKey: "uploadProgress")
          if metadata.isEmpty {
            message.removeValue(forKey: "metadata")
          } else {
            message["metadata"] = metadata
          }
        }
      }
    }
    if changed && postDelta {
      postChatDeltaLocked(
        chatId: chatId, inserted: [], updated: [messageId], deleted: [], source: "upload")
    }
    return changed
  }

  private func markLiveMessageDeletedLocked(chatId: String, messageId: String) {
    if var perChat = liveMessageRowsByChat[chatId] {
      perChat.removeValue(forKey: messageId)
      if perChat.isEmpty {
        liveMessageRowsByChat.removeValue(forKey: chatId)
      } else {
        liveMessageRowsByChat[chatId] = perChat
      }
    }
    var deleted = deletedMessageIdsByChat[chatId] ?? Set<String>()
    deleted.insert(messageId)
    deletedMessageIdsByChat[chatId] = deleted
    deleteCachedHistoryMessageLocked(chatId: chatId, messageId: messageId)
    storeMergedChatHistoryIfLoadedLocked(chatId: chatId)
    feedCoreDeleteLocked(chatId: chatId, messageId: messageId)
  }

  private func deleteCachedHistoryMessageLocked(chatId: String, messageId: String) {
    if var historyRows = historyRowsByChat[chatId] {
      historyRows.removeAll { self.messageId(fromRow: $0) == messageId }
      historyRowsByChat[chatId] = historyRows
    }

    var sqliteBefore = -1
    var sqliteAfter = -1
    if let userId = chatHistoryCacheUserIdLocked(), messageStore.isAvailable {
      sqliteBefore = messageStore.messageCount(userId: userId, chatId: chatId)
      messageStore.deleteMessages(
        userId: userId,
        chatId: chatId,
        messageIds: [messageId]
      )
      VibeCoreStoreBridge.tombstoneMessages(
        userId: userId, chatId: chatId, messageIds: [messageId])
      VibeCoreStoreBridge.repairChat(
        userId: userId, chatId: chatId, reason: "message-deleted")
      sqliteAfter = messageStore.messageCount(userId: userId, chatId: chatId)
    }

    var legacyRemoved = false
    if let cacheKey = chatHistoryCacheKeyLocked(chatId: chatId),
      let data = UserDefaults.standard.data(forKey: cacheKey),
      let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
      let legacyRows = object as? [[String: Any]]
    {
      let retained = legacyRows.filter { self.messageId(fromRow: $0) != messageId }
      if retained.count != legacyRows.count {
        legacyRemoved = true
        if retained.isEmpty {
          UserDefaults.standard.removeObject(forKey: cacheKey)
        } else if JSONSerialization.isValidJSONObject(retained),
          let nextData = try? JSONSerialization.data(withJSONObject: retained)
        {
          UserDefaults.standard.set(nextData, forKey: cacheKey)
        }
      }
    }

    NSLog(
      "[HistoryStore] DELETE chat=%@ id=%@ sqlite=%d→%d legacy=%@",
      String(chatId.prefix(12)),
      String(messageId.suffix(12)),
      sqliteBefore,
      sqliteAfter,
      legacyRemoved ? "Y" : "N"
    )
  }

  private func findMessagePayloadLocked(chatId: String, messageId: String) -> [String: Any]? {
    if let liveMessage = liveMessageRowsByChat[chatId]?[messageId]?["message"] as? [String: Any] {
      return liveMessage
    }
    guard let rows = historyRowsByChat[chatId] else { return nil }
    for row in rows {
      guard normalizedString(row["kind"]) == "message" else { continue }
      guard let message = row["message"] as? [String: Any] else { continue }
      if normalizedString(message["id"]) == messageId {
        return message
      }
    }
    return nil
  }

  private func optimisticReactionBucketsLocked(
    chatId: String, messageId: String, emoji: String
  ) -> [[String: Any]] {
    let existing = findMessagePayloadLocked(chatId: chatId, messageId: messageId)?["reactions"]
      as? [[String: Any]] ?? []
    var buckets: [(emoji: String, count: Int, selected: Bool)] = existing.compactMap { bucket in
      guard let value = normalizedString(bucket["emoji"]),
        let count = parseLongValue(bucket["count"]), count > 0
      else { return nil }
      return (
        value,
        Int(clamping: count),
        parseBooleanLike(bucket["isSelected"] ?? bucket["is_selected"]) ?? false)
    }
    let selectedIndex = buckets.firstIndex(where: \.selected)
    if let selectedIndex, ChatReactionKey.matches(buckets[selectedIndex].emoji, emoji) {
      buckets[selectedIndex].count -= 1
      buckets[selectedIndex].selected = false
    } else {
      if let selectedIndex {
        buckets[selectedIndex].count -= 1
        buckets[selectedIndex].selected = false
      }
      if let next = buckets.firstIndex(where: { ChatReactionKey.matches($0.emoji, emoji) }) {
        buckets[next].count += 1
        buckets[next].selected = true
      } else {
        buckets.append((emoji, 1, true))
      }
    }
    return buckets.filter { $0.count > 0 }.map {
      ["emoji": $0.emoji, "count": $0.count, "isSelected": $0.selected]
    }
  }

  @discardableResult
  private func applyMessageEngagementLocked(
    chatId: String, messageId: String, reactions: [[String: Any]]?, viewCount: Int64?
  ) -> Bool {
    var changed = mutateLiveMessagePayloadLocked(chatId: chatId, messageId: messageId) { message in
      if let reactions { message["reactions"] = reactions }
      if let viewCount { message["viewCount"] = viewCount }
    }
    if var rows = historyRowsByChat[chatId] {
      for index in rows.indices {
        guard var message = rows[index]["message"] as? [String: Any],
          normalizedString(message["id"]) == messageId
        else { continue }
        let previous = message
        if let reactions { message["reactions"] = reactions }
        if let viewCount { message["viewCount"] = viewCount }
        if !(message as NSDictionary).isEqual(to: previous) {
          rows[index]["message"] = message
          changed = true
        }
        break
      }
      historyRowsByChat[chatId] = rows
    }
    guard changed,
      let message = findMessagePayloadLocked(chatId: chatId, messageId: messageId)
    else { return changed }
    feedCoreRawFramesLocked(chatId: chatId, rawMessages: [message], source: .chatTopic)
    storeMergedChatHistoryIfLoadedLocked(chatId: chatId)
    return true
  }

  private func buildLiveRowPayloadLocked(
    chatId: String,
    messageId: String,
    fromId: String?,
    type: String?,
    timestampMs: Int64,
    encryptedContent: String?,
    decryptedFields: [String: Any],
    forceIsMe: Bool? = nil,
    forceEdited: Bool = false,
    forceEditedAt: Any? = nil
  ) -> [String: Any] {
    let normalizedType = normalizedString(type)?.lowercased() ?? "text"
    let normalizedFrom = normalizedString(fromId)
    let isMe = forceIsMe ?? (
      normalizedUpper(normalizedFrom) != nil
        && normalizedUpper(normalizedFrom) == currentUserIdLocked()
    )
    let text = normalizedString(decryptedFields["text"]) ?? ""
    let mediaUrl = normalizedString(decryptedFields["mediaUrl"])
    let localMediaUrl = normalizedString(
      decryptedFields["localMediaUrl"] ?? decryptedFields["local_media_url"])
    let fileName = normalizedString(decryptedFields["fileName"])
    let fileSize = parseLongValue(decryptedFields["fileSize"])
    let latitude = parseDoubleValue(decryptedFields["latitude"])
    let longitude = parseDoubleValue(decryptedFields["longitude"])
    let duration = parseDoubleValue(decryptedFields["duration"])
    let replyToId = normalizedString(decryptedFields["replyToId"])
    let replyPreviewTitle = normalizedString(
      decryptedFields["replyPreviewTitle"] ?? decryptedFields["reply_preview_title"]
        ?? decryptedFields["replyAuthorName"] ?? decryptedFields["reply_author_name"])
    let replyPreviewText = normalizedString(
      decryptedFields["replyPreviewText"] ?? decryptedFields["reply_preview_text"]
        ?? decryptedFields["replyText"] ?? decryptedFields["reply_text"])
    let replyPreview = decryptedFields["replyPreview"] ?? decryptedFields["reply_preview"]
    let caption = normalizedString(decryptedFields["caption"])
    let waveform = parseWaveformArray(decryptedFields["waveform"])
    let isEdited = forceEdited || ((decryptedFields["isEdited"] as? Bool) == true)
    let editedAt = forceEditedAt ?? decryptedFields["editedAt"]

    var metadata = (decryptedFields["metadata"] as? [String: Any]) ?? [:]
    if let waveform { metadata["waveform"] = waveform }
    if let width = decryptedFields["width"] { metadata["width"] = width }
    if let height = decryptedFields["height"] { metadata["height"] = height }
    if let thumbnailBase64 = decryptedFields["thumbnailBase64"] {
      metadata["thumbnailBase64"] = thumbnailBase64
    }
    if let isVideoNote = decryptedFields["isVideoNote"] { metadata["isVideoNote"] = isVideoNote }
    if let fileSize { metadata["fileSize"] = fileSize }
    if let latitude { metadata["latitude"] = latitude }
    if let longitude { metadata["longitude"] = longitude }
    if let viewOnce = decryptedFields["viewOnce"] { metadata["viewOnce"] = viewOnce }
    if let mediaTtlSeconds = decryptedFields["mediaTtlSeconds"] {
      metadata["mediaTtlSeconds"] = mediaTtlSeconds
    }
    if let contact = decryptedFields["contact"] { metadata["contact"] = contact }
    if let caption { metadata["caption"] = caption }
    if let mediaKey = decryptedFields["mediaKey"] { metadata["mediaKey"] = mediaKey }
    if let localMediaUrl { metadata["localMediaUrl"] = localMediaUrl }
    if let replyPreviewTitle { metadata["replyPreviewTitle"] = replyPreviewTitle }
    if let replyPreviewText { metadata["replyPreviewText"] = replyPreviewText }
    if let replyPreview { metadata["replyPreview"] = replyPreview }
    if let stickerId = normalizedString(decryptedFields["stickerId"]) {
      metadata["stickerId"] = stickerId
    }
    if let stickerPackId = normalizedString(
      decryptedFields["stickerPackId"] ?? decryptedFields["packId"])
    {
      metadata["stickerPackId"] = stickerPackId
      metadata["packId"] = stickerPackId
    }
    if let stickerBundleFileName = normalizedString(
      decryptedFields["stickerBundleFileName"] ?? decryptedFields["bundleFileName"])
    {
      metadata["stickerBundleFileName"] = stickerBundleFileName
      metadata["bundleFileName"] = stickerBundleFileName
    }
    if let emoji = normalizedString(decryptedFields["emoji"]) {
      metadata["emoji"] = emoji
    }
    if metadata["cover"] == nil,
      let cover = normalizedString(
        decryptedFields["cover"] ?? decryptedFields["coverUrl"] ?? decryptedFields["artworkUrl"])
    {
      metadata["cover"] = cover
    }
    if metadata["artist"] == nil, let artist = normalizedString(decryptedFields["artist"]) {
      metadata["artist"] = artist
    }
    if metadata["source"] == nil, let source = normalizedString(decryptedFields["source"]) {
      metadata["source"] = source
    }

    var message: [String: Any] = [
      "id": messageId,
      "chatId": chatId,
      "timestampMs": Double(timestampMs),
      "timestamp": formatMessageTimeLabel(timestampMs: timestampMs),
      "text": text,
      "type": normalizedType,
      "isMe": isMe,
      "isEdited": isEdited,
      "bubbleShape": [
        "showTail": true,
        "borderTopLeftRadius": 18,
        "borderTopRightRadius": 18,
        "borderBottomRightRadius": 18,
        "borderBottomLeftRadius": 18,
      ],
    ]
    if let normalizedFrom { message["fromId"] = normalizedFrom }
    if isMe { message["status"] = "sent" }
    if let editedAt { message["editedAt"] = editedAt }
    if let encryptedContent { message["encryptedContent"] = encryptedContent }
    if let mediaUrl { message["mediaUrl"] = mediaUrl }
    if let localMediaUrl { message["localMediaUrl"] = localMediaUrl }
    if let fileName { message["fileName"] = fileName }
    if let duration { message["duration"] = duration }
    if let replyToId { message["replyToId"] = replyToId }
    if let replyPreviewTitle { message["replyPreviewTitle"] = replyPreviewTitle }
    if let replyPreviewText { message["replyPreviewText"] = replyPreviewText }
    if let replyPreview { message["replyPreview"] = replyPreview }
    if let caption { message["caption"] = caption }
    if let contact = decryptedFields["contact"] { message["contact"] = contact }
    if !metadata.isEmpty { message["metadata"] = metadata }

    return [
      "kind": "message",
      "key": "m-\(messageId)",
      "message": message,
    ]
  }

  private static let agentUserId = "00000000-0000-0000-0000-000000000001"

  private func ingestMirroredUserTopicMessageLocked(
    chatId: String, payload: [String: Any]
  ) -> (messageId: String, inserted: Bool)? {
    guard !nativeJoinedChatIds.contains(chatId) else { return nil }
    guard let messageId = normalizedString(payload["id"] ?? payload["message_id"]) else {
      return nil
    }
    guard deletedMessageIdsByChat[chatId]?.contains(messageId) != true else {
      NSLog(
        "[ChatEngine] user-topic mirror ignored for locally deleted message chatId=%@ messageId=%@",
        String(chatId.prefix(12)),
        String(messageId.prefix(12))
      )
      return nil
    }
    let wasPresent =
      liveMessageRowsByChat[chatId]?[messageId] != nil
      || (historyRowsByChat[chatId] ?? []).contains { self.messageId(fromRow: $0) == messageId }
    guard
      let insertedMessageId = applyNativeIncomingMessageEventLocked(
        chatId: chatId, payload: payload, postDelta: true)
    else { return nil }
    return (insertedMessageId, !wasPresent)
  }

  private func applyNativeIncomingMessageEventLocked(
    chatId: String, payload: [String: Any], postDelta: Bool = true
  )
    -> String?
  {
    guard let messageId = normalizedString(payload["id"] ?? payload["message_id"]) else {
      return nil
    }

    let fromId = normalizedString(payload["fromId"] ?? payload["from_id"])
    let encryptedContent = normalizedString(
      payload["encryptedContent"] ?? payload["encrypted_content"])
    let type = normalizedString(payload["type"]) ?? "text"
    let timestampMs = parseLongValue(payload["timestamp"]) ?? Int64(nowMs())
    let senderIsMe =
      normalizedUpper(fromId) != nil && normalizedUpper(fromId) == currentUserIdLocked()
    let existingMessageIsMe =
      (findMessagePayloadLocked(chatId: chatId, messageId: messageId)?["isMe"] as? Bool) == true
    let isMe = senderIsMe || existingMessageIsMe
    let rawMediaUrl = normalizedString(payload["mediaUrl"] ?? payload["media_url"])
      .map(durableMediaURLStringLocked)
    let rawFileName = normalizedString(payload["fileName"] ?? payload["file_name"])
    let rawMediaKey = normalizedString(payload["mediaKey"] ?? payload["media_key"])
    let derivedFileName = deriveFileNameFromURL(rawMediaUrl)
    let encryptedLooksHybrid = isLikelyHybridCiphertext(encryptedContent)
    let encryptedIsMls = VibeSecureSessions.isMlsEnvelope(encryptedContent)

    let rawMetadataForAgentFields = payload["metadata"] as? [String: Any]
    let agentName = firstNormalizedString(
      payload["agentName"], payload["agent_name"],
      rawMetadataForAgentFields?["agentName"], rawMetadataForAgentFields?["agent_name"])
    let agentId = firstNormalizedString(
      payload["agentId"], payload["agent_id"],
      rawMetadataForAgentFields?["agentId"], rawMetadataForAgentFields?["agent_id"])
    let isAgentMessage =
      (payload["isAgentMessage"] as? Bool == true)
      || (payload["is_agent_message"] as? Bool == true)
      || (rawMetadataForAgentFields?["isAgentMessage"] as? Bool == true)
      || (rawMetadataForAgentFields?["is_agent_message"] as? Bool == true)
      || (normalizedString(fromId)?.lowercased() == Self.agentUserId)
      || agentId != nil
      || agentName != nil
      || (rawMediaUrl?.lowercased().contains("/uploads/agent-docs/") == true)
      || (rawMediaUrl?.lowercased().contains("/api/agent/document/") == true)
    let plainContent = firstNormalizedString(
      payload["plainContent"], payload["plain_content"], payload["plaintext"],
      rawMetadataForAgentFields?["plainContent"], rawMetadataForAgentFields?["plain_content"])
    let agentUserId =
      firstNormalizedString(
        payload["agentUserId"], payload["agent_user_id"],
        rawMetadataForAgentFields?["agentUserId"], rawMetadataForAgentFields?["agent_user_id"])
      ?? (isAgentMessage ? fromId : nil)
    let agentUsername = firstNormalizedString(
      payload["agentUsername"], payload["agent_username"],
      payload["agentHandle"], payload["agent_handle"],
      rawMetadataForAgentFields?["agentUsername"], rawMetadataForAgentFields?["agent_username"],
      rawMetadataForAgentFields?["agentHandle"], rawMetadataForAgentFields?["agent_handle"])

    let hadEncryptedContent = encryptedContent != nil && !encryptedContent!.isEmpty
    let decryptedText: String = {
      if isAgentMessage, let plainContent, !plainContent.isEmpty {
        return plainContent
      }
      guard let encryptedContent, !encryptedContent.isEmpty else {
        return ""
      }
      if encryptedIsMls {
        if isMe {
          return VibeSecureSessions.shared.ownPlaintext(
            messageId: messageId, envelope: encryptedContent) ?? ""
        }
        return VibeSecureSessions.shared.open(
          chatId: chatId, envelope: encryptedContent, isMine: false, messageId: messageId) ?? ""
      }
      if !encryptedLooksHybrid {
        return encryptedContent
      }
      guard let privateKey = decryptPrivateKeyLocked() else {
        VibeLog.error(
          "no private key to open with", category: "crypto",
          metadata: chatEngineCryptoMeta(chatId: chatId, messageId: messageId, isMine: isMe))
        return ""
      }
      return chatEngineDecryptHybridMessage(
        privateKey: privateKey, ciphertext: encryptedContent, isMyMessage: isMe,
        chatId: chatId, messageId: messageId)
    }()
    let decryptionFailed =
      !isMe && !isAgentMessage && hadEncryptedContent && (encryptedLooksHybrid || encryptedIsMls)
      && decryptedText.isEmpty

    if decryptionFailed, ChatEngine.noteDecryptFailureOnce(messageId: messageId) {
      VibeLog.error(
        "message failed to decrypt", category: "crypto",
        metadata: [
          "chat": String(chatId.prefix(12)),
          "msg": String(messageId.suffix(12)),
          "envelope": encryptedIsMls ? "mls" : (encryptedLooksHybrid ? "hybrid" : "plain"),
          "mine": isMe ? "Y" : "N",
          "type": normalizedString(type) ?? "-",
          "wireMediaUrl": (rawMediaUrl?.isEmpty == false) ? "Y" : "N",
          "wireMediaKey": (rawMediaKey?.isEmpty == false) ? "Y" : "N",
          "rsaKey": (decryptPrivateKeyLocked() != nil) ? "present" : "MISSING",
        ])
    }

    var decryptedFields = parseDecryptedMessagePayload(decryptedText)
    if let metadata = payload["metadata"] as? [String: Any], !metadata.isEmpty {
      var merged = (decryptedFields["metadata"] as? [String: Any]) ?? [:]
      for (key, value) in metadata {
        if merged[key] == nil { merged[key] = value }
      }
      if let remote = metadata["mediaUrl"] as? String ?? metadata["media_url"] as? String,
        remote.hasPrefix("http")
      {
        merged["mediaUrl"] = remote
      }
      decryptedFields["metadata"] = merged
    }
    if let rawReplyToId = normalizedString(payload["replyToId"] ?? payload["reply_to_id"]),
      normalizedString(decryptedFields["replyToId"]) == nil
    {
      decryptedFields["replyToId"] = rawReplyToId
    }
    if let rawMediaUrl, !rawMediaUrl.isEmpty, normalizedString(decryptedFields["mediaUrl"]) == nil {
      decryptedFields["mediaUrl"] = rawMediaUrl
    }
    if let rawMediaKey, !rawMediaKey.isEmpty, normalizedString(decryptedFields["mediaKey"]) == nil {
      decryptedFields["mediaKey"] = rawMediaKey
    }
    let fileNameForRow =
      rawFileName
      ?? ((normalizedString(type)?.lowercased() == "file") ? derivedFileName : nil)
    if let fileNameForRow, !fileNameForRow.isEmpty,
      normalizedString(decryptedFields["fileName"]) == nil
    {
      decryptedFields["fileName"] = fileNameForRow
    }
    let dimMetadata = payload["metadata"] as? [String: Any]
    if decryptedFields["width"] == nil,
      let rawWidth = parseDoubleValue(dimMetadata?["width"] ?? dimMetadata?["media_width"])
    {
      decryptedFields["width"] = rawWidth
    }
    if decryptedFields["height"] == nil,
      let rawHeight = parseDoubleValue(dimMetadata?["height"] ?? dimMetadata?["media_height"])
    {
      decryptedFields["height"] = rawHeight
    }
    if !isAgentMessage, hadEncryptedContent, !decryptionFailed,
      normalizedString(decryptedFields["text"]) == nil,
      normalizedString(decryptedFields["caption"]) == nil,
      normalizedString(decryptedFields["mediaUrl"]) == nil,
      ChatEngine.cryptoLogOnce("empty-row", messageId: messageId)
    {
      var line = chatEngineCryptoMeta(chatId: chatId, messageId: messageId, isMine: isMe)
      line["stage"] = "live-row"
      line["env"] = encryptedIsMls ? "mls" : (encryptedLooksHybrid ? "hybrid" : "plain")
      line["type"] = type
      line["plainLen"] = String(decryptedText.count)
      line["fields"] = decryptedFields.keys.sorted().prefix(8).joined(separator: ",")
      VibeLog.warning("opened but row has nothing to render", category: "crypto", metadata: line)
    }
    var row = buildLiveRowPayloadLocked(
      chatId: chatId,
      messageId: messageId,
      fromId: fromId,
      type: type,
      timestampMs: timestampMs,
      encryptedContent: encryptedContent,
      decryptedFields: decryptedFields,
      forceIsMe: isMe
    )
    if isAgentMessage, var message = row["message"] as? [String: Any] {
      message["isAgentMessage"] = true
      message["isMe"] = false
      if let agentName { message["agentName"] = agentName }
      if let agentId { message["agentId"] = agentId }
      if let agentUserId { message["agentUserId"] = agentUserId }
      if let agentUsername {
        message["agentUsername"] = agentUsername.trimmingCharacters(
          in: CharacterSet(charactersIn: "@"))
      }
      if let plainContent { message["plainContent"] = plainContent }
      if let plainContent, !plainContent.isEmpty { message["text"] = plainContent }
      row["message"] = message
    }
    if decryptionFailed, var message = row["message"] as? [String: Any] {
      message["decryptionFailed"] = true
      row["message"] = message
    }
    if ["image", "gif", "file", "voice", "video", "music", "sticker"].contains(type.lowercased()), isMe,
      let existingMessage = findMessagePayloadLocked(chatId: chatId, messageId: messageId),
      let localPlaybackUrl = extractLocalPlaybackMediaURLFromMessage(existingMessage)
    {
      NSLog(
        "[ChatEngine] preserve local media url on incoming echo chatId=%@ messageId=%@ local=%@",
        chatId,
        messageId,
        localPlaybackUrl
      )
      row = mergeLocalPlaybackMediaURLIntoRow(row: row, localUrl: localPlaybackUrl)
    }
    if isMe, let existingMessage = findMessagePayloadLocked(chatId: chatId, messageId: messageId) {
      let existingMeta = existingMessage["metadata"] as? [String: Any]
      let existingBlobs =
        (existingMeta?["agentBridgeAttachmentsEnc"] as? [String])?.filter { !$0.isEmpty } ?? []
      let existingThumbs =
        (existingMeta?["attachmentThumbnailsB64"] as? [String])?.filter { !$0.isEmpty } ?? []
      let existingThumb =
        (existingMeta?["thumbnailBase64"] as? String)
        ?? (existingMessage["thumbnailBase64"] as? String)
      if var message = row["message"] as? [String: Any] {
        var meta = (message["metadata"] as? [String: Any]) ?? [:]
        var changed = false
        if !existingBlobs.isEmpty,
          ((meta["agentBridgeAttachmentsEnc"] as? [String])?.isEmpty ?? true)
        {
          meta["agentBridgeAttachmentsEnc"] = existingBlobs
          changed = true
        }
        if !existingThumbs.isEmpty,
          ((meta["attachmentThumbnailsB64"] as? [String])?.isEmpty ?? true)
        {
          meta["attachmentThumbnailsB64"] = existingThumbs
          changed = true
        }
        if let existingThumb, !existingThumb.isEmpty,
          ((meta["thumbnailBase64"] as? String)?.isEmpty ?? true)
        {
          meta["thumbnailBase64"] = existingThumb
          message["thumbnailBase64"] = existingThumb
          changed = true
        }
        let existingType = ((existingMessage["type"] as? String) ?? "").lowercased()
        let nextType = ((message["type"] as? String) ?? "").lowercased()
        if ["image", "gif", "video"].contains(existingType), nextType == "text" || nextType.isEmpty
        {
          message["type"] = existingType
          changed = true
        }
        if changed {
          message["metadata"] = meta
          row["message"] = message
        }
      }
    }
    let coreFrames = coreProjectedFramesLocked(
      chatId: chatId, rawMessages: [payload], rows: [row])
    feedCoreRawFramesLocked(chatId: chatId, rawMessages: coreFrames, source: .chatTopic)
    let inserted = upsertLiveMessageRowLocked(chatId: chatId, messageId: messageId, row: row)
    appendJournalLocked(
      event: "native-message-row-upsert",
      payload: [
        "chatId": chatId,
        "messageId": messageId,
        "type": type,
      ])
    state["updatedAt"] = nowMs()
    if postDelta {
      let source =
        messageId.hasPrefix("stream-") || messageId.hasPrefix("lan-") ? "stream" :
        messageId.hasPrefix("bridge-") ? "bridge" : "live"
      postChatDeltaLocked(
        chatId: chatId,
        inserted: inserted ? [messageId] : [],
        updated: inserted ? [] : [messageId],
        deleted: [],
        source: source)
    }
    return messageId
  }

  private func extractLocalPlaybackMediaURLFromMessage(_ message: [String: Any]) -> String? {
    let metadata = message["metadata"] as? [String: Any]
    let candidates: [Any?] = [
      message["localMediaUrl"],
      message["local_media_url"],
      metadata?["localMediaUrl"],
      metadata?["local_media_url"],
      message["mediaUrl"],
      message["media_url"],
      metadata?["mediaUrl"],
      metadata?["media_url"],
      message["uri"],
      metadata?["uri"],
      message["audioUrl"],
      message["audio_url"],
      metadata?["audioUrl"],
      metadata?["audio_url"],
    ]
    for candidate in candidates {
      guard let value = normalizedString(candidate), isLocalMediaURI(value) else { continue }
      return value
    }
    return nil
  }

  private func mergeLocalPlaybackMediaURLIntoRow(row: [String: Any], localUrl: String) -> [String:
    Any]
  {
    var mutableRow = row
    guard var message = mutableRow["message"] as? [String: Any] else {
      return mutableRow
    }
    message["localMediaUrl"] = localUrl
    var metadata = (message["metadata"] as? [String: Any]) ?? [:]
    metadata["localMediaUrl"] = localUrl
    message["metadata"] = metadata
    mutableRow["message"] = message
    return mutableRow
  }

  private func applyNativeChatMutationEventLocked(
    chatId: String,
    event: String,
    payload: [String: Any]
  ) -> (messageId: String, action: String)? {
    guard !chatId.isEmpty else { return nil }
    guard let messageId = normalizedString(payload["messageId"] ?? payload["message_id"]) else {
      return nil
    }
    switch event {
    case "message-edited":
      guard deletedMessageIdsByChat[chatId]?.contains(messageId) != true else { return nil }
      let editedAtValue = payload["editedAt"] ?? payload["edited_at"]
      let encryptedContent = normalizedString(
        payload["encryptedContent"] ?? payload["encrypted_content"])

      if findMessagePayloadLocked(chatId: chatId, messageId: messageId) == nil,
        let mirroredMessage = payload["message"] as? [String: Any],
        normalizedString(mirroredMessage["id"] ?? mirroredMessage["message_id"]) == messageId
      {
        _ = applyNativeIncomingMessageEventLocked(
          chatId: chatId, payload: mirroredMessage, postDelta: false)
      }
      guard let existingMessage = findMessagePayloadLocked(chatId: chatId, messageId: messageId)
      else { return nil }

      if let incomingEditedAt = parseLongValue(editedAtValue),
        let currentEditedAt = parseLongValue(
          existingMessage["editedAt"] ?? existingMessage["edited_at"]),
        incomingEditedAt < currentEditedAt
      {
        return nil
      }
      let existingMetadata = existingMessage["metadata"] as? [String: Any]
      let fromId = normalizedString(existingMessage["fromId"] ?? existingMessage["from_id"])
      let wireMetadataEarly = payload["metadata"] as? [String: Any]
      let isViewOnceTombstone =
        (wireMetadataEarly?["mediaExpired"] as? Bool) == true
        || ((wireMetadataEarly?["service"] as? [String: Any])?["kind"] as? String)
          == "view_once_expired"
      let type =
        isViewOnceTombstone
        ? (normalizedString(payload["type"]) ?? "system")
        : (normalizedString(existingMessage["type"]) ?? "text")
      let timestampMs =
        parseLongValue(existingMessage["timestampMs"] ?? existingMessage["timestamp"])
        ?? Int64(nowMs())
      let isMe = normalizedUpper(fromId) != nil && normalizedUpper(fromId) == currentUserIdLocked()
      func noteMutationOpenFailure(_ stage: String, env: String) {
        guard ChatEngine.cryptoLogOnce("mutation-open", messageId: messageId) else { return }
        var line = chatEngineCryptoMeta(chatId: chatId, messageId: messageId, isMine: isMe)
        line["stage"] = stage
        line["env"] = env
        VibeLog.error("edited message failed to decrypt", category: "crypto", metadata: line)
      }
      let decryptedFields: [String: Any] = {
        guard let encryptedContent, !encryptedContent.isEmpty else {
          return [:]
        }
        if VibeSecureSessions.isMlsEnvelope(encryptedContent) {
          if isMe {
            if let mine = VibeSecureSessions.shared.ownPlaintext(
              messageId: messageId, envelope: encryptedContent)
            {
              return parseDecryptedMessagePayload(mine)
            }
            noteMutationOpenFailure("mls-own-no-plaintext", env: "mls")
            return [:]
          }
          guard
            let opened = VibeSecureSessions.shared.open(
              chatId: chatId, envelope: encryptedContent, isMine: false, messageId: messageId)
          else {
            noteMutationOpenFailure("mls-open", env: "mls")
            return [:]
          }
          return parseDecryptedMessagePayload(opened)
        }
        if !isLikelyHybridCiphertext(encryptedContent) {
          return parseDecryptedMessagePayload(encryptedContent)
        }
        guard let privateKey = decryptPrivateKeyLocked() else {
          noteMutationOpenFailure("no-rsa-key", env: "hybrid")
          return [:]
        }
        let decrypted = chatEngineDecryptHybridMessage(
          privateKey: privateKey,
          ciphertext: encryptedContent,
          isMyMessage: isMe,
          chatId: chatId,
          messageId: messageId
        )
        if decrypted.isEmpty {
          noteMutationOpenFailure("hybrid-open", env: "hybrid")
        }
        return parseDecryptedMessagePayload(decrypted)
      }()
      var hydratedFields = decryptedFields
      let wireMetadata = payload["metadata"] as? [String: Any] ?? wireMetadataEarly
      if isViewOnceTombstone {
        hydratedFields["mediaUrl"] = nil
        hydratedFields["localMediaUrl"] = nil
        hydratedFields["fileName"] = nil
        hydratedFields["mediaKey"] = nil
        hydratedFields["thumbnailBase64"] = nil
        if let wireMetadata, !wireMetadata.isEmpty {
          hydratedFields["metadata"] = wireMetadata
        }
      } else {
        if normalizedString(hydratedFields["mediaUrl"]) == nil {
          hydratedFields["mediaUrl"] =
            existingMessage["mediaUrl"] ?? existingMessage["media_url"]
            ?? existingMetadata?["mediaUrl"] ?? existingMetadata?["media_url"]
        }
        if normalizedString(hydratedFields["fileName"]) == nil {
          hydratedFields["fileName"] =
            existingMessage["fileName"] ?? existingMessage["file_name"]
            ?? existingMetadata?["fileName"] ?? existingMetadata?["file_name"]
        }
        if normalizedString(hydratedFields["mediaKey"]) == nil {
          hydratedFields["mediaKey"] =
            existingMessage["mediaKey"] ?? existingMessage["media_key"]
            ?? existingMetadata?["mediaKey"] ?? existingMetadata?["media_key"]
        }
        if hydratedFields["thumbnailBase64"] == nil {
          hydratedFields["thumbnailBase64"] =
            existingMessage["thumbnailBase64"] ?? existingMessage["thumbnail_base64"]
            ?? existingMetadata?["thumbnailBase64"] ?? existingMetadata?["thumbnail_base64"]
        }
        if let existingMetadata, !existingMetadata.isEmpty {
          var mergedMetadata = existingMetadata
          if let editedMetadata = hydratedFields["metadata"] as? [String: Any] {
            mergedMetadata.merge(editedMetadata) { _, new in new }
          }
          if let wireMetadata {
            mergedMetadata.merge(wireMetadata) { _, new in new }
          }
          hydratedFields["metadata"] = mergedMetadata
        } else if let wireMetadata, !wireMetadata.isEmpty {
          var mergedMetadata = (hydratedFields["metadata"] as? [String: Any]) ?? [:]
          mergedMetadata.merge(wireMetadata) { _, new in new }
          hydratedFields["metadata"] = mergedMetadata
        }
      }
      if let plain = normalizedString(payload["plainContent"] ?? payload["plaintext"]),
        !plain.isEmpty
      {
        hydratedFields["text"] = plain
        hydratedFields["plainContent"] = plain
      }
      var row = buildLiveRowPayloadLocked(
        chatId: chatId,
        messageId: messageId,
        fromId: fromId,
        type: type,
        timestampMs: timestampMs,
        encryptedContent: encryptedContent
          ?? normalizedString(
            existingMessage["encryptedContent"] ?? existingMessage["encrypted_content"]),
        decryptedFields: hydratedFields,
        forceEdited: true,
        forceEditedAt: editedAtValue
      )
      if var nextMessage = row["message"] as? [String: Any] {
        if let reactions = existingMessage["reactions"] { nextMessage["reactions"] = reactions }
        if let viewCount = existingMessage["viewCount"] { nextMessage["viewCount"] = viewCount }
        row["message"] = nextMessage
      }
      upsertLiveMessageRowLocked(chatId: chatId, messageId: messageId, row: row)
      appendJournalLocked(
        event: "native-message-edited",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
          "editedAt": editedAtValue as Any,
        ])
      state["updatedAt"] = nowMs()
      return (messageId, "edited")
    case "message-deleted":
      DispatchQueue.global(qos: .utility).async {
        VibeSecureSessions.shared.forget(messageId: messageId)
      }
      if normalizedString(payload["reason"]) == "view_once",
        let existingMessage = findMessagePayloadLocked(chatId: chatId, messageId: messageId)
      {
        let existingType = normalizedString(existingMessage["type"]) ?? "image"
        let noun = existingType == "video" ? "Video" : "Photo"
        let label = "\(noun) viewed"
        let fromId = normalizedString(existingMessage["fromId"] ?? existingMessage["from_id"])
        let timestampMs =
          parseLongValue(existingMessage["timestampMs"] ?? existingMessage["timestamp"])
          ?? Int64(nowMs())
        let tombstoneFields: [String: Any] = [
          "text": "",
          "plainContent": label,
          "metadata": [
            "mediaExpired": true,
            "mediaExpiryReason": "viewed",
            "text": label,
            "service": [
              "kind": "view_once_expired",
              "status": "expired",
              "text": label,
            ],
          ],
        ]
        let row = buildLiveRowPayloadLocked(
          chatId: chatId,
          messageId: messageId,
          fromId: fromId,
          type: "system",
          timestampMs: timestampMs,
          encryptedContent: nil,
          decryptedFields: tombstoneFields,
          forceEdited: true
        )
        upsertLiveMessageRowLocked(chatId: chatId, messageId: messageId, row: row)
        appendJournalLocked(
          event: "native-message-edited",
          payload: [
            "chatId": chatId,
            "messageId": messageId,
            "reason": "view_once",
          ])
        state["updatedAt"] = nowMs()
        return (messageId, "edited")
      }
      removeMessageIndicesLocked(chatId: chatId, messageId: messageId)
      markLiveMessageDeletedLocked(chatId: chatId, messageId: messageId)
      applyPinnedUpdateLocked(
        chatId: chatId,
        messageId: messageId,
        pinned: false,
        payload: [:],
        trigger: "message_deleted",
        refreshRemote: false
      )
      appendJournalLocked(
        event: "native-message-deleted",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
        ])
      state["updatedAt"] = nowMs()
      return (messageId, "deleted")
    default:
      return nil
    }
  }

  private func applyNativeChatEventLocked(
    chatId: String,
    event: String,
    payload: [String: Any]
  ) -> (messageId: String, status: String)? {
    guard !chatId.isEmpty else { return nil }
    switch event {
    case "message-delivered":
      guard let messageId = normalizedString(payload["messageId"] ?? payload["message_id"]) else {
        return nil
      }
      guard deletedMessageIdsByChat[chatId]?.contains(messageId) != true else { return nil }
      upsertReceiptLocked(chatId: chatId, messageId: messageId, status: "delivered")
      upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "delivered")
      appendJournalLocked(
        event: "native-message-delivered",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
        ])
      return (messageId, "delivered")
    case "message-read":
      guard let messageId = normalizedString(payload["messageId"] ?? payload["message_id"]) else {
        return nil
      }
      guard deletedMessageIdsByChat[chatId]?.contains(messageId) != true else { return nil }
      upsertReceiptLocked(chatId: chatId, messageId: messageId, status: "read")
      upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "read")
      appendJournalLocked(
        event: "native-message-read",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
        ])
      return (messageId, "read")
    default:
      return nil
    }
  }

  private func fetchPinnedMessagesLocked(chatId: String, trigger: String) {
    guard !chatId.isEmpty else { return }
    guard chatId != "saved_messages" else {
      pinnedMessagesByChatId[chatId] = []
      VibeDebugLog.log("[ChatEngine][Pin] fetchPinnedMessages skip saved_messages trigger=%@", trigger)
      return
    }
    guard !pinnedFetchInFlightChatIds.contains(chatId) else {
      VibeDebugLog.log(
        "[ChatEngine][Pin] fetchPinnedMessages skipped (in-flight) chatId=%@ trigger=%@",
        chatId,
        trigger
      )
      return
    }
    guard let apiBase = apiBaseURLLocked() else {
      VibeDebugLog.log(
        "[ChatEngine][Pin] fetchPinnedMessages skipped (missing apiBase) chatId=%@ trigger=%@",
        chatId,
        trigger
      )
      return
    }
    let token = authHeaderTokenLocked() ?? ""

    pinnedFetchInFlightChatIds.insert(chatId)
    VibeDebugLog.log(
      "[ChatEngine][Pin] fetchPinnedMessages start chatId=%@ trigger=%@ tokenPresent=%@",
      chatId,
      trigger,
      token.isEmpty ? "false" : "true"
    )
    appendJournalLocked(
      event: "native-pinned-load-start",
      payload: ["chatId": chatId, "trigger": trigger]
    )

    var request = URLRequest(
      url: apiBase.appendingPathComponent("api").appendingPathComponent("chat")
        .appendingPathComponent(chatId).appendingPathComponent("pinned_messages"))
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      self.queue.async {
        self.pinnedFetchInFlightChatIds.remove(chatId)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

        if let error {
          NSLog(
            "[ChatEngine][Pin] fetchPinnedMessages network error chatId=%@ trigger=%@ error=%@",
            chatId,
            trigger,
            error.localizedDescription
          )
          self.appendJournalLocked(
            event: "native-pinned-load-error",
            payload: [
              "chatId": chatId,
              "trigger": trigger,
              "error": error.localizedDescription,
            ])
          self.postChangeLocked(
            reason: "chatPinnedUpdated",
            userInfo: ["chatId": chatId, "loading": false]
          )
          return
        }

        guard (200...299).contains(statusCode), let data else {
          NSLog(
            "[ChatEngine][Pin] fetchPinnedMessages http error chatId=%@ trigger=%@ status=%@",
            chatId,
            trigger,
            String(statusCode)
          )
          if statusCode == 401 {
            Task { await AppSessionGuard.shared.recover(reason: "pinned-http-401") }
          }
          self.appendJournalLocked(
            event: "native-pinned-load-error",
            payload: [
              "chatId": chatId,
              "trigger": trigger,
              "status": statusCode,
            ])
          self.postChangeLocked(
            reason: "chatPinnedUpdated",
            userInfo: ["chatId": chatId, "loading": false]
          )
          return
        }

        let nextPins = self.parsePinnedMessagesResponse(data: data, chatId: chatId)
        let nextPinIds = nextPins.compactMap {
          self.normalizedString($0["messageId"] ?? $0["message_id"])
        }
        VibeDebugLog.log(
          "[ChatEngine][Pin] fetchPinnedMessages ok chatId=%@ trigger=%@ status=%@ count=%@ ids=%@",
          chatId,
          trigger,
          String(statusCode),
          String(nextPins.count),
          nextPinIds.joined(separator: ",")
        )
        let previousPins = self.pinnedMessagesByChatId[chatId] ?? []
        let previousIds = Set(
          previousPins.compactMap { self.normalizedString($0["messageId"] ?? $0["message_id"]) })
        let nextIds = Set(
          nextPins.compactMap { self.normalizedString($0["messageId"] ?? $0["message_id"]) })
        let allIds = previousIds.union(nextIds)
        for messageId in allIds {
          self.setMessagePinnedStateLocked(
            chatId: chatId,
            messageId: messageId,
            pinned: nextIds.contains(messageId)
          )
        }

        self.pinnedMessagesByChatId[chatId] = nextPins
        self.state["updatedAt"] = self.nowMs()
        self.appendJournalLocked(
          event: "native-pinned-load-ok",
          payload: [
            "chatId": chatId,
            "trigger": trigger,
            "count": nextPins.count,
            "status": statusCode,
          ])
        let snapshot = self.statusSnapshotLocked()
        self.postChangeLocked(
          reason: "chatPinnedUpdated",
          userInfo: [
            "chatId": chatId,
            "loading": false,
            "count": nextPins.count,
            "state": snapshot,
          ]
        )
      }
    }.resume()
  }

  private func parsePinnedMessagesResponse(data: Data, chatId: String) -> [[String: Any]] {
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let response = object as? [String: Any]
    else {
      return []
    }

    let rawItems = (response["data"] as? [Any]) ?? []
    return rawItems.compactMap { rawItem in
      guard let raw = rawItem as? [String: Any] else { return nil }
      return normalizePinnedEntry(raw, chatId: chatId)
    }
  }

  private func normalizePinnedEntry(
    _ raw: [String: Any],
    chatId: String,
    fallbackMessageId: String? = nil
  ) -> [String: Any]? {
    let messageId =
      normalizedString(raw["messageId"] ?? raw["message_id"] ?? raw["id"] ?? fallbackMessageId)
    guard let messageId, !messageId.isEmpty else { return nil }

    var entry: [String: Any] = [
      "messageId": messageId,
      "chatId": chatId,
    ]
    if let pinnedAt = raw["pinnedAt"] ?? raw["pinned_at"] {
      entry["pinnedAt"] = pinnedAt
    } else {
      entry["pinnedAt"] = nowMs()
    }
    if let timestamp = raw["timestamp"] ?? raw["messageTimestamp"] ?? raw["message_timestamp"] {
      entry["timestamp"] = timestamp
    }
    if let type = normalizedString(raw["type"] ?? raw["messageType"] ?? raw["message_type"]) {
      entry["type"] = type
    }
    if let mediaURL = normalizedString(raw["mediaUrl"] ?? raw["media_url"]) {
      entry["mediaUrl"] = mediaURL
    }
    if let fileName = normalizedString(raw["fileName"] ?? raw["file_name"]) {
      entry["fileName"] = fileName
    }
    if let text = normalizedString(raw["text"] ?? raw["plainContent"] ?? raw["plain_content"]) {
      entry["text"] = text
    }
    return entry
  }

  private func applyPinnedUpdateLocked(
    chatId: String,
    messageId: String,
    pinned: Bool,
    payload: [String: Any],
    trigger: String,
    refreshRemote: Bool
  ) {
    setMessagePinnedStateLocked(chatId: chatId, messageId: messageId, pinned: pinned)

    var pins = pinnedMessagesByChatId[chatId] ?? []
    pins.removeAll {
      normalizedString($0["messageId"] ?? $0["message_id"]) == messageId
    }
    if pinned {
      let entry =
        normalizePinnedEntry(payload, chatId: chatId, fallbackMessageId: messageId)
        ?? [
          "messageId": messageId,
          "chatId": chatId,
          "pinnedAt": nowMs(),
        ]
      pins.insert(entry, at: 0)
    }
    pinnedMessagesByChatId[chatId] = pins
    NSLog(
      "[ChatEngine][Pin] applyPinnedUpdate chatId=%@ messageId=%@ pinned=%@ trigger=%@ pinCount=%@",
      chatId,
      messageId,
      pinned ? "true" : "false",
      trigger,
      String(pins.count)
    )
    state["updatedAt"] = nowMs()
    appendJournalLocked(
      event: "native-pinned-updated",
      payload: [
        "chatId": chatId,
        "messageId": messageId,
        "pinned": pinned,
        "trigger": trigger,
      ])
    if refreshRemote {
      fetchPinnedMessagesLocked(chatId: chatId, trigger: trigger)
    }
  }

  private func setMessagePinnedStateLocked(chatId: String, messageId: String, pinned: Bool) {
    let liveChanged = mutateLiveMessagePayloadLocked(chatId: chatId, messageId: messageId) { message in
      message["isPinned"] = pinned
      message["pinned"] = pinned
    }

    guard var rows = historyRowsByChat[chatId] else {
      if liveChanged {
        postChatDeltaLocked(
          chatId: chatId, inserted: [], updated: [messageId], deleted: [], source: "pin")
      }
      return
    }
    var changed = false
    for index in rows.indices {
      guard normalizedString(rows[index]["kind"]) == "message" else { continue }
      guard var message = rows[index]["message"] as? [String: Any] else { continue }
      guard normalizedString(message["id"]) == messageId else { continue }
      let previousMessage = message
      message["isPinned"] = pinned
      message["pinned"] = pinned
      guard !(message as NSDictionary).isEqual(to: previousMessage) else { continue }
      var row = rows[index]
      row["message"] = message
      rows[index] = row
      changed = true
    }
    if changed {
      historyRowsByChat[chatId] = rows
    }
    if liveChanged || changed {
      postChatDeltaLocked(
        chatId: chatId, inserted: [], updated: [messageId], deleted: [], source: "pin")
    }
  }

  private func joinNativeChatTopicIfNeededLocked(chatId: String) {
    guard !chatId.isEmpty else { return }
    guard !isBuiltInAgentChatId(chatId) else {
      VibeDebugLog.log("[ChatEngine][Route] skip realtime join for built-in agent chatId=%@", chatId)
      return
    }
    guard chatId != "saved_messages" else {
      VibeDebugLog.log("[ChatEngine][Route] skip realtime join for saved_messages")
      return
    }
    guard let client = phoenixClient else {
      VibeDebugLog.log("[ChatEngine][Route] joinNativeChatTopic deferred chatId=%@ reason=no_socket", chatId)
      scheduleReconnectLocked(reason: "join_chat_no_socket")
      DispatchQueue.global(qos: .utility).async { [weak self] in
        self?.ensureNativeTransport(trigger: "join_chat_no_socket")
      }
      return
    }
    guard state["connected"] as? Bool == true else {
      VibeDebugLog.log("[ChatEngine][Route] joinNativeChatTopic deferred chatId=%@ reason=not_connected", chatId)
      scheduleReconnectLocked(reason: "join_chat_not_connected")
      DispatchQueue.global(qos: .utility).async { [weak self] in
        self?.ensureNativeTransport(trigger: "join_chat_not_connected")
      }
      return
    }
    if nativeJoinedChatIds.contains(chatId) { return }
    if nativeChatJoinRefsByRef.values.contains(chatId) { return }
    VibeDebugLog.log("[ChatEngine][Route] joinNativeChatTopic start chatId=%@", chatId)
    let ref = client.join(topic: chatTopic(for: chatId), payload: [:])
    nativeChatJoinRefsByRef[ref] = chatId
    appendJournalLocked(event: "native-chat-join-start", payload: ["chatId": chatId, "ref": ref])
  }

  private func recoverStaleNativeChatTopicLocked(chatId: String, reason: String) {
    guard !chatId.isEmpty else { return }

    let inFlight = nativePendingMessagePushRefs.filter { _, pending in
      pending.chatId == chatId
    }
    for (ref, pending) in inFlight {
      nativePendingMessagePushRefs.removeValue(forKey: ref)
      nativeMessagePushSentAtMs.removeValue(forKey: ref)
      upsertLocalStatusLocked(
        chatId: pending.chatId,
        messageId: pending.messageId,
        status: "pending",
        allowDowngrade: true
      )
      if let draft = pendingOutboundDraftsByMessageId[pending.messageId] {
        queueOutboundDraftLocked(
          chatId: pending.chatId,
          messageId: pending.messageId,
          payload: draft,
          reason: reason
        )
      }
    }

    nativeJoinedChatIds.remove(chatId)
    nativeChatJoinRefsByRef = nativeChatJoinRefsByRef.filter { _, joinedChatId in
      joinedChatId != chatId
    }
    appendJournalLocked(
      event: "native-chat-topic-recover",
      payload: [
        "chatId": chatId,
        "reason": reason,
        "requeued": inFlight.count,
      ])
    NSLog(
      "[OutboundRetry] rejoin stale topic chatId=%@ reason=%@ requeued=%d",
      chatId, reason, inFlight.count)

    let hasDemand =
      openChatChannels[chatId] != nil
      || !(pendingOutboundQueueByChat[chatId]?.isEmpty ?? true)
      || !inFlight.isEmpty
    if hasDemand {
      joinNativeChatTopicIfNeededLocked(chatId: chatId)
    }
    state["updatedAt"] = nowMs()
    postChangeLocked(
      reason: "chatChannelStateChanged",
      userInfo: ["chatId": chatId, "recovery": reason]
    )
  }

  func logPendingSendDiagnostics(chatId: String, pendingMessageIds: [String]) {
    guard !pendingMessageIds.isEmpty else { return }
    queue.async { [weak self] in
      guard let self else { return }
      let queued = Set(self.pendingOutboundQueueByChat[chatId] ?? [])
      var withDraft = 0
      var inReplayQueue = 0
      var orphaned: [String] = []
      let uploading = Set(self.activeMediaUploadTasksByMessageId.keys)
      for id in pendingMessageIds {
        if queued.contains(id) { inReplayQueue += 1 }
        let local = self.localStatusIndex[chatId]?[id]
        if local == "sending" || uploading.contains(id) { continue }
        if self.pendingOutboundDraftsByMessageId[id] != nil {
          withDraft += 1
        } else {
          orphaned.append(id)
        }
      }
      NSLog(
        "[PendingAudit] chat=%@ pending=%d withDraft=%d inReplayQueue=%d orphaned=%d orphanSample=[%@]",
        String(chatId.prefix(12)), pendingMessageIds.count, withDraft, inReplayQueue,
        orphaned.count,
        orphaned.prefix(6).map { String($0.prefix(12)) }.joined(separator: ","))
      guard !orphaned.isEmpty else { return }
      self.resolveStrandedPendingLocked(chatId: chatId, messageIds: orphaned)
    }
  }

  private func resolveStrandedPendingLocked(chatId: String, messageIds: [String]) {
    guard !messageIds.isEmpty else { return }
    for messageId in messageIds {
      upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
    }
    let persisted = persistStrandedResolutionLocked(chatId: chatId, messageIds: messageIds)
    appendJournalLocked(
      event: "native-pending-stranded-resolved",
      payload: ["chatId": chatId, "count": messageIds.count])
    postChangeLocked(
      reason: "chatMessageChanged",
      userInfo: ["chatId": chatId, "action": "updated"])
    NSLog(
      "[PendingAudit] chat=%@ RESOLVED %d stranded rows → failed, %d rewritten on disk (no draft existed, so nothing was ever going to send them)",
      String(chatId.prefix(12)), messageIds.count, persisted)
  }

  private func persistStrandedResolutionLocked(chatId: String, messageIds: [String]) -> Int {
    guard let userId = chatHistoryCacheUserIdLocked(), messageStore.isAvailable else { return 0 }
    let targets = Set(messageIds)
    let payloads = messageStore.recentMessagePayloads(
      userId: userId, chatId: chatId, limit: max(targets.count * 4, 2_000))
    var entries: [(messageId: String, ts: Int64, payload: Data)] = []
    entries.reserveCapacity(targets.count)
    for data in payloads {
      guard
        var row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let messageId = messageId(fromRow: row),
        targets.contains(messageId)
      else { continue }
      if var message = row["message"] as? [String: Any] {
        message["status"] = "error"
        row["message"] = message
      } else {
        row["status"] = "error"
      }
      guard
        JSONSerialization.isValidJSONObject(row),
        let rewritten = try? JSONSerialization.data(withJSONObject: row, options: [])
      else { continue }
      entries.append((messageId, messageTimestampMs(fromRow: row), rewritten))
    }
    guard !entries.isEmpty else { return 0 }
    messageStore.upsertMessages(userId: userId, chatId: chatId, entries: entries)
    VibeCoreStoreBridge.mirrorRows(
      userId: userId, chatId: chatId, entries: entries, keepNewest: 0)
    return entries.count
  }

  private func queueOutboundDraftLocked(
    chatId: String, messageId: String, payload: [String: Any], reason: String
  ) {
    if isBuiltInAgentChatId(chatId) {
      pendingOutboundDraftsByMessageId.removeValue(forKey: messageId)
      if var ids = pendingOutboundQueueByChat[chatId] {
        ids.removeAll { $0 == messageId }
        if ids.isEmpty {
          pendingOutboundQueueByChat.removeValue(forKey: chatId)
        } else {
          pendingOutboundQueueByChat[chatId] = ids
        }
      }
      removeMessageIndicesLocked(chatId: chatId, messageId: messageId)
      markLiveMessageDeletedLocked(chatId: chatId, messageId: messageId)
      persistOutboundStateLocked()
      appendJournalLocked(
        event: "native-outgoing-drop",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
          "reason": "built_in_agent_surface:\(reason)",
        ])
      postChatDeltaLocked(
        chatId: chatId, inserted: [], updated: [], deleted: [messageId], source: "delete")
      return
    }
    var payload = payload
    let isBridgeDraft = bridgeProviderForOutboundDraftLocked(payload, fallbackChatId: chatId) != nil
    if isBridgeDraft {
      payload["__bridgeQueuedAtMs"] = nowMs()
    }
    if payload["__queuedAtMs"] == nil {
      payload["__queuedAtMs"] = nowMs()
    }
    pendingOutboundDraftsByMessageId[messageId] = payload
    var ids = pendingOutboundQueueByChat[chatId] ?? []
    if ids.contains(messageId) { return }
    ids.append(messageId)
    pendingOutboundQueueByChat[chatId] = ids
    appendJournalLocked(
      event: "native-outgoing-queued",
      payload: [
        "chatId": chatId,
        "messageId": messageId,
        "reason": reason,
      ])
    persistOutboundStateLocked()
    postChangeLocked(
      reason: "outgoingMessageQueued",
      userInfo: [
        "chatId": chatId,
        "messageId": messageId,
        "reason": reason,
      ])
    guard isBridgeDraft else { return }
    queue.asyncAfter(deadline: .now() + .milliseconds(queuedOutboundVisibleErrorDelayMs)) { [weak self] in
      guard let self else { return }
      let stillQueued = self.pendingOutboundQueueByChat[chatId]?.contains(messageId) == true
      let stillDrafted = self.pendingOutboundDraftsByMessageId[messageId] != nil
      guard stillQueued && stillDrafted else { return }
      let currentStatus = self.localStatusIndex[chatId]?[messageId]
      if currentStatus == "sent" || currentStatus == "delivered" || currentStatus == "read" {
        return
      }
      let expiredDraft = self.pendingOutboundDraftsByMessageId[messageId] ?? [:]
      let isBridgeDraft =
        self.bridgeProviderForOutboundDraftLocked(expiredDraft, fallbackChatId: chatId) != nil
      self.upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
      if isBridgeDraft {
        self.removeQueuedOutboundDraftLocked(chatId: chatId, messageId: messageId, dropDraft: false)
      }
      self.appendJournalLocked(
        event: "native-outgoing-visible-error",
        payload: ["chatId": chatId, "messageId": messageId, "reason": reason]
      )
      self.postChangeLocked(
        reason: "messageStatusChanged",
        userInfo: ["chatId": chatId, "messageId": messageId, "status": "error"]
      )
    }
  }

  private func messagePushFailureReasonLocked(_ payload: [String: Any]) -> String {
    var maps: [[String: Any]] = [payload]
    for key in ["response", "error", "details"] {
      if let nested = payload[key] as? [String: Any] {
        maps.append(nested)
      }
    }
    for map in maps {
      for key in ["reason", "error", "message", "code"] {
        if let value = normalizedString(map[key])?.lowercased(), !value.isEmpty {
          return value
        }
      }
    }
    return "push_error"
  }

  private func isPermanentMessagePushFailureLocked(_ payload: [String: Any]) -> Bool {
    let reason = messagePushFailureReasonLocked(payload)
    let permanentMarkers = [
      "unauthorized", "forbidden", "not_member", "not a member", "blocked",
      "invalid_payload", "invalid message", "invalid_message", "message_too_large",
      "unsupported_type", "chat_disabled", "account_disabled", "permission_denied",
    ]
    return permanentMarkers.contains { reason.contains($0) }
  }

  private func cancelScheduledOutboundReplayLocked(
    messageId: String,
    resetAttempt: Bool
  ) {
    outboundReplayWorkItemsByMessageId.removeValue(forKey: messageId)?.cancel()
    if resetAttempt {
      outboundReplayAttemptsByMessageId.removeValue(forKey: messageId)
    }
  }

  private func scheduleRetryableOutboundReplayLocked(
    chatId: String,
    messageId: String,
    draft: [String: Any],
    reason: String,
    recycleTransport: Bool
  ) {
    upsertLocalStatusLocked(
      chatId: chatId,
      messageId: messageId,
      status: "pending",
      allowDowngrade: true
    )
    queueOutboundDraftLocked(
      chatId: chatId,
      messageId: messageId,
      payload: draft,
      reason: "retryable_\(reason)"
    )

    let attempt = (outboundReplayAttemptsByMessageId[messageId] ?? 0) + 1
    outboundReplayAttemptsByMessageId[messageId] = attempt
    let delay = outboundReplayDelays[
      min(max(0, attempt - 1), outboundReplayDelays.count - 1)]
    cancelScheduledOutboundReplayLocked(messageId: messageId, resetAttempt: false)

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.outboundReplayWorkItemsByMessageId.removeValue(forKey: messageId)
      guard
        self.pendingOutboundQueueByChat[chatId]?.contains(messageId) == true,
        self.pendingOutboundDraftsByMessageId[messageId] != nil
      else { return }
      self.appendJournalLocked(
        event: "native-outgoing-auto-retry",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
          "attempt": attempt,
          "reason": reason,
        ])
      self.scheduleReplayQueuedOutboundLocked(
        chatId: chatId, trigger: "push_error_backoff")
      self.ensureNativeTransportIfDemandedLocked(trigger: "push_error_backoff")
    }
    outboundReplayWorkItemsByMessageId[messageId] = workItem
    queue.asyncAfter(deadline: .now() + delay, execute: workItem)

    appendJournalLocked(
      event: "native-outgoing-retry-scheduled",
      payload: [
        "chatId": chatId,
        "messageId": messageId,
        "attempt": attempt,
        "delayMs": Int(delay * 1000),
        "reason": reason,
        "recycleTransport": recycleTransport,
      ])
    NSLog(
      "[ChatEngine] send queued for auto-retry chatId=%@ messageId=%@ reason=%@ attempt=%d delayMs=%d recycle=%@",
      chatId, messageId, reason, attempt, Int(delay * 1000),
      recycleTransport ? "Y" : "N")
    postChangeLocked(
      reason: "messageStatusChanged",
      userInfo: [
        "chatId": chatId,
        "messageId": messageId,
        "status": "pending",
      ])

    if recycleTransport, let client = phoenixClient {
      appendJournalLocked(
        event: "native-outgoing-recycle-socket",
        payload: [
          "chatId": chatId,
          "messageId": messageId,
          "reason": reason,
        ])
      handleNativeSocketClosed(
        code: 4001,
        reason: "outbound_recycle:\(reason)"
      )
      DispatchQueue.global(qos: .utility).async {
        client.disconnect()
      }
    }
  }

  private func removeQueuedOutboundDraftLocked(chatId: String, messageId: String, dropDraft: Bool) {
    if var ids = pendingOutboundQueueByChat[chatId] {
      ids.removeAll { $0 == messageId }
      if ids.isEmpty {
        pendingOutboundQueueByChat.removeValue(forKey: chatId)
      } else {
        pendingOutboundQueueByChat[chatId] = ids
      }
    }
    if dropDraft {
      cancelScheduledOutboundReplayLocked(messageId: messageId, resetAttempt: true)
      pendingOutboundDraftsByMessageId.removeValue(forKey: messageId)
    }
    persistOutboundStateLocked()
  }

  private static let maxQueuedOutboundReplay = 500

  private static let queuedOutboundReplayMaxAgeMs = 15 * 60 * 1000

  private static let maxHealedOutboundQueue = 100

  private static let outboundDrainIntervalMs = 400

  private static let outboundDrainMaxAttempts = 3

  private var outboundDrainInFlightByChat: [String: String] = [:]
  private var outboundDrainAttemptsByMessageId: [String: Int] = [:]

  private func expireStaleQueuedOutboundLocked(trigger: String) {
    let now = Int64(nowMs())
    var expiredByChat: [String: [String]] = [:]
    for (chatId, ids) in pendingOutboundQueueByChat {
      for messageId in ids {
        guard let draft = pendingOutboundDraftsByMessageId[messageId] else { continue }
        let queuedAtMs = parseLongValue(draft["__queuedAtMs"]) ?? 0
        guard queuedAtMs <= 0 || now - queuedAtMs > Int64(Self.queuedOutboundReplayMaxAgeMs)
        else { continue }
        expiredByChat[chatId, default: []].append(messageId)
      }
    }
    guard !expiredByChat.isEmpty else { return }
    for (chatId, messageIds) in expiredByChat {
      for messageId in messageIds {
        upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
        removeQueuedOutboundDraftLocked(chatId: chatId, messageId: messageId, dropDraft: false)
      }
      NSLog(
        "[ChatEngine] expireStaleQueuedOutbound chatId=%@ trigger=%@ count=%d — older than %dms, failed instead of left pending",
        String(chatId.prefix(12)), trigger, messageIds.count, Self.queuedOutboundReplayMaxAgeMs)
      appendJournalLocked(
        event: "native-outgoing-queue-expired",
        payload: ["chatId": chatId, "count": messageIds.count, "trigger": trigger])
    }
  }

  private func scheduleReplayQueuedOutboundLocked(chatId: String, trigger: String) {
    if isBuiltInAgentChatId(chatId) {
      dropQueuedOutboundForChatLocked(chatId: chatId, reason: "built_in_agent_replay_\(trigger)")
      return
    }
    let ids = pendingOutboundQueueByChat[chatId] ?? []
    guard !ids.isEmpty else { return }

    expireStaleQueuedOutboundLocked(trigger: trigger)
    guard ids.count <= Self.maxQueuedOutboundReplay else {
      NSLog(
        "[ChatEngine] scheduleReplayQueuedOutboundLocked REFUSED chatId=%@ trigger=%@ count=%d — queue past %d, replaying it would fan out",
        chatId, trigger, ids.count, Self.maxQueuedOutboundReplay)
      appendJournalLocked(
        event: "native-outgoing-replay-refused",
        payload: ["chatId": chatId, "count": ids.count, "trigger": trigger])
      return
    }

    NSLog(
      "[ChatEngine] scheduleReplayQueuedOutboundLocked chatId=%@ trigger=%@ count=%d", chatId,
      trigger, ids.count)
    var drafts: [[String: Any]] = []
    var expiredIds: [String] = []
    for messageId in ids {
      if nativePendingMessagePushRefs.values.contains(where: {
        $0.chatId == chatId && $0.messageId == messageId
      }) {
        continue
      }
      guard let draft = pendingOutboundDraftsByMessageId[messageId] else { continue }
      let queuedAtMs = parseLongValue(draft["__queuedAtMs"]) ?? 0
      if queuedAtMs <= 0 || Int64(nowMs()) - queuedAtMs > Int64(Self.queuedOutboundReplayMaxAgeMs) {
        expiredIds.append(messageId)
        continue
      }
      if let provider = bridgeProviderForOutboundDraftLocked(draft, fallbackChatId: chatId) {
        let queuedAtMs = parseLongValue(draft["__bridgeQueuedAtMs"]) ?? 0
        if Int64(nowMs()) - queuedAtMs > Int64(bridgeQueuedReplayMaxAgeMs) {
          markVolatileBridgeSendErrorLocked(
            chatId: chatId,
            messageId: messageId,
            reason: "queued_expired_\(trigger)",
            provider: provider
          )
          continue
        }
      }
      drafts.append(draft)
    }
    if !expiredIds.isEmpty {
      for messageId in expiredIds {
        upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
        removeQueuedOutboundDraftLocked(chatId: chatId, messageId: messageId, dropDraft: false)
      }
      NSLog(
        "[ChatEngine] scheduleReplayQueuedOutboundLocked EXPIRED chatId=%@ trigger=%@ count=%d — older than %dms, failed instead of sent",
        String(chatId.prefix(12)), trigger, expiredIds.count, Self.queuedOutboundReplayMaxAgeMs)
      appendJournalLocked(
        event: "native-outgoing-replay-expired",
        payload: ["chatId": chatId, "count": expiredIds.count, "trigger": trigger])
    }

    guard !drafts.isEmpty else { return }

    let replayPeerAgentId = resolvePeerAgentIdLocked(chatId: chatId, peerUserIdHint: nil)
    if let mlsDraft = drafts.first(where: {
      ($0["__requiresConfirmedMls"] as? Bool) == true
    }), (replayPeerAgentId ?? "").isEmpty,
      !VibeSecureSessions.shared.isPeerConfirmed(chatId: chatId) {
      guard
        let mlsPeerUserId = normalizedUpper(
          mlsDraft["peerUserId"] ?? mlsDraft["peer_user_id"]
            ?? chatPeerUserIdsByChatId[chatId])
      else { return }
      ensureDirectMlsReadinessLocked(chatId: chatId, peerUserId: mlsPeerUserId)
      return
    }

    let hasNonPeerDraft = drafts.contains { draft in
      (draft["isGroup"] as? Bool) == true
        || (draft["isGroupOrChannel"] as? Bool) == true
        || normalizedString(draft["peerAgentId"] ?? draft["peer_agent_id"]) != nil
    }
    let hasMlsDraft = drafts.contains { ($0["__requiresConfirmedMls"] as? Bool) == true }
    if !hasNonPeerDraft, !hasMlsDraft, chatId != "saved_messages",
      !isVolatileBridgeAgentChatLocked(chatId: chatId),
      resolveFriendPublicKeyLocked(chatId: chatId, peerUserIdHint: nil) == nil
    {
      NSLog(
        "[ChatEngine] scheduleReplayQueuedOutboundLocked DEFERRED chatId=%@ trigger=%@ count=%d — no peer key; fetching once instead of replaying",
        String(chatId.prefix(12)), trigger, drafts.count)
      appendJournalLocked(
        event: "native-outgoing-replay-deferred",
        payload: ["chatId": chatId, "count": drafts.count, "trigger": trigger])
      scheduleFriendPublicKeyFetchLocked(
        chatId: chatId, peerUserIdHint: nil, trigger: "replay_\(trigger)")
      return
    }

    guard outboundDrainInFlightByChat[chatId] == nil else { return }
    guard let draft = drafts.first,
      let draftId = normalizedString(draft["messageId"] ?? draft["message_id"])
    else { return }

    let attempts = (outboundDrainAttemptsByMessageId[draftId] ?? 0) + 1
    outboundDrainAttemptsByMessageId[draftId] = attempts
    guard attempts <= Self.outboundDrainMaxAttempts else {
      NSLog(
        "[ChatEngine] outbox EXHAUSTED chatId=%@ id=%@ attempts=%d — failed instead of retried",
        String(chatId.prefix(12)), String(draftId.suffix(12)), attempts)
      upsertLocalStatusLocked(chatId: chatId, messageId: draftId, status: "error")
      removeQueuedOutboundDraftLocked(chatId: chatId, messageId: draftId, dropDraft: false)
      outboundDrainAttemptsByMessageId.removeValue(forKey: draftId)
      return
    }

    outboundDrainInFlightByChat[chatId] = draftId
    NSLog(
      "[ChatEngine] outbox DRAIN chatId=%@ id=%@ attempt=%d queued=%d trigger=%@",
      String(chatId.prefix(12)), String(draftId.suffix(12)), attempts, drafts.count, trigger)
    appendJournalLocked(
      event: "native-outgoing-replay-scheduled",
      payload: [
        "chatId": chatId,
        "count": drafts.count,
        "trigger": trigger,
        "messageId": draftId,
        "attempt": attempts,
      ])
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      _ = self.sendMessage(draft)
      self.queue.asyncAfter(deadline: .now() + .milliseconds(Self.outboundDrainIntervalMs)) {
        [weak self] in
        guard let self else { return }
        self.outboundDrainInFlightByChat.removeValue(forKey: chatId)
        if !(self.pendingOutboundQueueByChat[chatId]?.contains(draftId) ?? false) {
          self.outboundDrainAttemptsByMessageId.removeValue(forKey: draftId)
        }
        self.scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "drain_tick")
      }
    }
  }

  private func rebuildOutboundDraftFromStoredRowLocked(
    chatId: String?, messageId targetMessageId: String
  ) -> [String: Any]? {
    let messageId = targetMessageId
    let resolvedChatId: String? = {
      if let chatId, !chatId.isEmpty { return chatId }
      return liveMessageRowsByChat.first(where: { $0.value[messageId] != nil })?.key
    }()
    guard let resolvedChatId, !resolvedChatId.isEmpty else { return nil }
    let row: [String: Any]? =
      liveMessageRowsByChat[resolvedChatId]?[messageId]
      ?? (historyRowsByChat[resolvedChatId] ?? []).first {
        self.messageId(fromRow: $0) == targetMessageId
      }
    guard let row else { return nil }
    guard let message = row["message"] as? [String: Any] else { return nil }
    guard (message["isMe"] as? Bool) ?? false else { return nil }
    let type = normalizedString(message["type"] ?? message["messageType"]) ?? "text"
    guard type == "text" else { return nil }
    let text = normalizedString(message["text"] ?? message["content"]) ?? ""
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    var draft: [String: Any] = [
      "chatId": resolvedChatId,
      "messageId": messageId,
      "text": text,
      "type": "text",
    ]
    if let replyToId = normalizedString(row["replyToId"] ?? row["reply_to_id"]) {
      draft["replyToId"] = replyToId
    }
    if let peerUserId = chatPeerUserIdsByChatId[resolvedChatId] {
      draft["peerUserId"] = peerUserId
      // Agent peers are server-side and never confirm MLS; demanding it here strands the retry.
      let rebuiltPeerAgentId = resolvePeerAgentIdLocked(
        chatId: resolvedChatId, peerUserIdHint: peerUserId)
      if let rebuiltPeerAgentId, !rebuiltPeerAgentId.isEmpty {
        draft["peerAgentId"] = rebuiltPeerAgentId
      } else {
        draft["__requiresConfirmedMls"] = true
      }
    }
    return draft
  }

  private func sweepOrphanedPendingLocked(trigger: String) {
    let now = Int64(nowMs())
    var strandedByChat: [String: [String]] = [:]
    for (chatId, statuses) in localStatusIndex {
      for (messageId, status) in statuses where status == "sending" || status == "pending" {
        if pendingOutboundQueueByChat[chatId]?.contains(messageId) == true { continue }
        if nativePendingMessagePushRefs.values.contains(where: {
          $0.chatId == chatId && $0.messageId == messageId
        }) { continue }
        let tsMs = liveMessageRowsByChat[chatId]?[messageId].flatMap {
          parseLongValue($0["timestampMs"] ?? $0["timestamp_ms"])
        } ?? 0
        guard tsMs <= 0 || now - tsMs > Int64(Self.queuedOutboundReplayMaxAgeMs) else { continue }
        strandedByChat[chatId, default: []].append(messageId)
      }
    }
    guard !strandedByChat.isEmpty else { return }
    for (chatId, messageIds) in strandedByChat {
      for messageId in messageIds {
        upsertLocalStatusLocked(chatId: chatId, messageId: messageId, status: "error")
      }
      NSLog(
        "[ChatEngine] outbox STRANDED chatId=%@ trigger=%@ count=%d — pending with no draft, failed so it can be retried",
        String(chatId.prefix(12)), trigger, messageIds.count)
      appendJournalLocked(
        event: "native-outgoing-stranded-swept",
        payload: ["chatId": chatId, "count": messageIds.count, "trigger": trigger])
    }
  }

  private func chatTopic(for chatId: String) -> String {
    "chat:\(chatId)"
  }

  private struct LocalMediaUploadResult {
    let remoteUrl: String
    let fileName: String?
    let fileSize: Int64?
    let mediaKey: String?
  }

  private struct LocalMediaUploadOutcome {
    let result: LocalMediaUploadResult?
    let reason: String?
  }

  private struct LocalMediaPreparationFailure: Error {
    let reason: String
  }

  private struct PreparedLocalMediaUpload {
    let fileData: Data
    let fileName: String
    let mimeType: String

    var fileSize: Int64 {
      Int64(fileData.count)
    }
  }

  private func isLocalMediaURI(_ raw: String) -> Bool {
    raw.hasPrefix("file://") || raw.hasPrefix("/") || raw.hasPrefix("content://")
  }

  private func prepareLocalMediaUploadLocked(
    fileData: Data,
    normalizedURL: URL,
    messageType: String,
    fileNameHint: String?
  ) -> Result<PreparedLocalMediaUpload, LocalMediaPreparationFailure> {
    let resolvedFileName = fileNameHint ?? normalizedURL.lastPathComponent
    return .success(
      PreparedLocalMediaUpload(
        fileData: fileData,
        fileName: resolvedFileName,
        mimeType: mediaMimeType(fileName: resolvedFileName, fallbackType: messageType)
      )
    )
  }

  private func uploadCategory(for messageType: String) -> String {
    switch messageType {
    case "image", "gif":
      return "image"
    case "voice", "music":
      return "audio"
    case "video":
      return "video"
    default:
      return "file"
    }
  }

  private func shouldEncryptUploadedMediaType(_ messageType: String) -> Bool {
    switch messageType {
    case "image", "gif", "voice", "music", "video", "file", "sticker":
      return true
    default:
      return false
    }
  }

  private func mediaMimeType(fileName: String, fallbackType: String) -> String {
    let ext = (fileName as NSString).pathExtension.lowercased()
    if !ext.isEmpty {
      switch ext {
      case "jpg", "jpeg":
        return "image/jpeg"
      case "png":
        return "image/png"
      case "gif":
        return "image/gif"
      case "webp":
        return "image/webp"
      case "heic":
        return "image/heic"
      case "m4a":
        return "audio/mp4"
      case "mp3":
        return "audio/mpeg"
      case "wav":
        return "audio/wav"
      case "aac":
        return "audio/aac"
      case "mp4":
        return "video/mp4"
      case "mov":
        return "video/quicktime"
      default:
        break
      }
    }
    switch fallbackType {
    case "image", "gif":
      return "image/jpeg"
    case "voice", "music":
      return "audio/mp4"
    case "video":
      return "video/mp4"
    default:
      return "application/octet-stream"
    }
  }

  private func resolveUploadURL(apiBase: URL) -> URL? {
    var base = apiBase.absoluteString
    while base.hasSuffix("/") {
      base.removeLast()
    }
    if base.hasSuffix("/api") {
      base = String(base.dropLast(4))
    }
    return URL(string: base + "/api/media/upload")
  }

  private func localFileURL(from rawURI: String) -> URL? {
    if rawURI.hasPrefix("file://"), let url = URL(string: rawURI), url.isFileURL {
      return url
    }
    if rawURI.hasPrefix("/") {
      return URL(fileURLWithPath: rawURI)
    }
    return nil
  }

  private func appendMultipartField(body: inout Data, boundary: String, name: String, value: String)
  {
    body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
    body.append(
      "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8) ?? Data())
    body.append("\(value)\r\n".data(using: .utf8) ?? Data())
  }

  fileprivate class UploadSessionDelegate: PinnedSessionDelegate, URLSessionTaskDelegate,
    URLSessionDataDelegate
  {
    var onProgress: ((Float) -> Void)?
    var onCompletion: ((Data?, HTTPURLResponse?, Error?) -> Void)?
    var responseData = Data()
    private var lastEmitTime: TimeInterval = 0
    private var lastEmittedProgress: Float = 0
    private let activityLock = NSLock()
    private var lastActivityTime: TimeInterval = CACurrentMediaTime()

    var lastActivityAt: TimeInterval {
      activityLock.lock()
      defer { activityLock.unlock() }
      return lastActivityTime
    }

    private func markActivity() {
      activityLock.lock()
      lastActivityTime = CACurrentMediaTime()
      activityLock.unlock()
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
      totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
      markActivity()
      guard totalBytesExpectedToSend > 0 else { return }
      let progress = Float(totalBytesSent) / Float(totalBytesExpectedToSend)
      let now = CACurrentMediaTime()
      let advanced = progress > lastEmittedProgress
      let shouldEmit =
        progress >= 0.999
        || progress <= 0.0
        || (progress - lastEmittedProgress) >= 0.02
        || (advanced && (now - lastEmitTime) >= 0.2)
      if shouldEmit {
        lastEmitTime = now
        lastEmittedProgress = progress
        onProgress?(progress)
      }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      markActivity()
      responseData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
      onCompletion?(responseData, task.response as? HTTPURLResponse, error)
    }
  }

  private func uploadLocalMediaLocked(
    localUri: String,
    messageType: String,
    fileNameHint: String?,
    userId: String,
    token: String,
    apiBase: URL,
    messageId: String? = nil,
    onProgress: ((Float) -> Void)? = nil
  ) -> LocalMediaUploadOutcome {
    guard let fileURL = localFileURL(from: localUri) else {
      return LocalMediaUploadOutcome(result: nil, reason: "invalid_local_media_uri")
    }
    let normalizedURL = fileURL.standardizedFileURL
    if !FileManager.default.fileExists(atPath: normalizedURL.path) {
      Thread.sleep(forTimeInterval: 0.5)
      guard FileManager.default.fileExists(atPath: normalizedURL.path) else {
        return LocalMediaUploadOutcome(result: nil, reason: "media_file_missing")
      }
    }
    let fileData: Data
    do {
      fileData = try Data(contentsOf: normalizedURL, options: [.mappedIfSafe])
    } catch {
      return LocalMediaUploadOutcome(result: nil, reason: "media_file_read_failed")
    }
    let preparedUpload: PreparedLocalMediaUpload
    switch prepareLocalMediaUploadLocked(
      fileData: fileData,
      normalizedURL: normalizedURL,
      messageType: messageType,
      fileNameHint: fileNameHint
    ) {
    case .success(let value):
      preparedUpload = value
    case .failure(let error):
      return LocalMediaUploadOutcome(result: nil, reason: error.reason)
    }
    let preparedFileSize = preparedUpload.fileSize
    let resolvedFileName = preparedUpload.fileName
    let resolvedMimeType = preparedUpload.mimeType
    let uploadType = uploadCategory(for: messageType)
    guard let uploadURL = resolveUploadURL(apiBase: apiBase) else {
      return LocalMediaUploadOutcome(result: nil, reason: "invalid_upload_url")
    }
    let uploadFileData: Data
    let mediaKey: String?
    if shouldEncryptUploadedMediaType(messageType) {
      do {
        let encrypted = try chatEngineEncryptMediaData(preparedUpload.fileData)
        uploadFileData = encrypted.encryptedData
        mediaKey = encrypted.keyBase64
      } catch {
        return LocalMediaUploadOutcome(result: nil, reason: "media_encrypt_failed")
      }
    } else {
      uploadFileData = preparedUpload.fileData
      mediaKey = nil
    }

    let boundary = "----VibeChatBoundary\(UUID().uuidString)"
    var request = URLRequest(url: uploadURL)
    request.httpMethod = "POST"
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 35

    var body = Data()
    appendMultipartField(body: &body, boundary: boundary, name: "user_id", value: userId)
    appendMultipartField(body: &body, boundary: boundary, name: "type", value: uploadType)
    body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
    body.append(
      "Content-Disposition: form-data; name=\"file\"; filename=\"\(resolvedFileName)\"\r\n".data(
        using: .utf8) ?? Data())
    body.append("Content-Type: \(resolvedMimeType)\r\n\r\n".data(using: .utf8) ?? Data())
    body.append(uploadFileData)
    body.append("\r\n".data(using: .utf8) ?? Data())
    body.append("--\(boundary)--\r\n".data(using: .utf8) ?? Data())
    let delegate = UploadSessionDelegate()
    delegate.onProgress = onProgress

    let semaphore = DispatchSemaphore(value: 0)
    var responseData: Data?
    var responseCode: Int?
    var responseError: Error?

    delegate.onCompletion = { data, res, error in
      if let error {
        responseError = error
      }
      responseCode = res?.statusCode
      responseData = data
      semaphore.signal()
    }

    let session = ChatPhoenixClient.makePinnedURLSession(delegate: delegate)
    defer { session.finishTasksAndInvalidate() }
    let task = session.uploadTask(with: request, from: body)
    if let messageId, !messageId.isEmpty {
      syncOnQueue {
        activeMediaUploadTasksByMessageId[messageId] = task
      }
    }
    let wireStartedAt = ProcessInfo.processInfo.systemUptime
    task.resume()
    let uploadStallTimeout: TimeInterval = 30
    var waitResult: DispatchTimeoutResult = .timedOut
    while true {
      if semaphore.wait(timeout: .now() + 2.0) == .success {
        waitResult = .success
        break
      }
      if CACurrentMediaTime() - delegate.lastActivityAt >= uploadStallTimeout {
        NSLog(
          "[MediaUpload] STALLED %@ bytes=%d elapsed=%.1fs idle>=%.0fs — cancelling",
          messageType, body.count,
          ProcessInfo.processInfo.systemUptime - wireStartedAt, uploadStallTimeout)
        break
      }
    }
    let wireSeconds = max(0.001, ProcessInfo.processInfo.systemUptime - wireStartedAt)
    NSLog(
      "[MediaUpload] %@ bytes=%d wire=%.2fs throughput=%.0fKB/s result=%@",
      messageType, body.count, wireSeconds,
      Double(body.count) / 1024.0 / wireSeconds,
      waitResult == .timedOut ? "timeout" : "done")
    if waitResult == .timedOut {
      task.cancel()
      if let messageId, !messageId.isEmpty {
        syncOnQueue {
          if activeMediaUploadTasksByMessageId[messageId] === task {
            activeMediaUploadTasksByMessageId.removeValue(forKey: messageId)
          }
        }
      }
      return LocalMediaUploadOutcome(result: nil, reason: "upload_timeout")
    }
    if let messageId, !messageId.isEmpty {
      syncOnQueue {
        if activeMediaUploadTasksByMessageId[messageId] === task {
          activeMediaUploadTasksByMessageId.removeValue(forKey: messageId)
        }
      }
    }
    if
      let nsError = responseError as NSError?,
      nsError.domain == NSURLErrorDomain,
      nsError.code == NSURLErrorCancelled
    {
      return LocalMediaUploadOutcome(result: nil, reason: "upload_canceled")
    }
    if responseError != nil {
      return LocalMediaUploadOutcome(result: nil, reason: "upload_failed")
    }
    guard let responseCode, (200...299).contains(responseCode), let responseData else {
      return LocalMediaUploadOutcome(result: nil, reason: "upload_failed")
    }
    guard
      let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
      let remoteUrl = normalizedString(json["url"] ?? json["mediaUrl"] ?? json["media_url"]),
      let uploadedURL = URL(string: remoteUrl),
      ["http", "https"].contains(uploadedURL.scheme?.lowercased() ?? ""),
      uploadedURL.host?.isEmpty == false
    else {
      return LocalMediaUploadOutcome(result: nil, reason: "invalid_upload_response")
    }
    return LocalMediaUploadOutcome(
      result: LocalMediaUploadResult(
        remoteUrl: remoteUrl,
        fileName: resolvedFileName,
        fileSize: preparedFileSize,
        mediaKey: mediaKey),
      reason: nil
    )
  }

  private func refreshMlsPeerConfirmationLocked(chatId: String) {
    guard !VibeSecureSessions.shared.isPeerConfirmed(chatId: chatId) else { return }
    guard let apiBase = apiBaseURLLocked() else { return }
    VibeSecureEstablishment.refreshPeerConfirmation(
      chatId: chatId, apiBase: apiBase, token: authHeaderTokenLocked())
  }

  private func ensureDirectMlsReadinessLocked(chatId: String, peerUserId: String) {
    guard !(pendingOutboundQueueByChat[chatId]?.isEmpty ?? true) else {
      cancelDirectMlsReadinessLocked(chatId: chatId, resetAttempts: true)
      return
    }
    if VibeSecureSessions.shared.isPeerConfirmed(chatId: chatId) {
      cancelDirectMlsReadinessLocked(chatId: chatId, resetAttempts: true)
      scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "mls_peer_confirmed")
      return
    }
    guard !directMlsReadinessInFlightChatIds.contains(chatId) else { return }
    guard let apiBase = apiBaseURLLocked() else { return }

    if !VibeSecureSessions.shared.hasSession(chatId: chatId),
      VibeSecureSessions.shared.peerKeysUnavailable(chatId: chatId)
    {
      scheduleDirectMlsRetryLocked(chatId: chatId, peerUserId: peerUserId, waitingForKeys: true)
      return
    }

    directMlsReadinessInFlightChatIds.insert(chatId)
    let settled: (Bool) -> Void = { [weak self] _ in
      guard let self else { return }
      self.queue.async {
        self.directMlsReadinessInFlightChatIds.remove(chatId)
        guard !(self.pendingOutboundQueueByChat[chatId]?.isEmpty ?? true) else {
          self.cancelDirectMlsReadinessLocked(chatId: chatId, resetAttempts: true)
          return
        }
        if VibeSecureSessions.shared.isPeerConfirmed(chatId: chatId) {
          self.cancelDirectMlsReadinessLocked(chatId: chatId, resetAttempts: true)
          self.scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "mls_peer_confirmed")
        } else if VibeSecureSessions.shared.hasSession(chatId: chatId) {
          self.scheduleDirectMlsRetryLocked(
            chatId: chatId, peerUserId: peerUserId, waitingForKeys: false)
        } else if VibeSecureSessions.shared.peerKeysUnavailable(chatId: chatId) {
          self.scheduleDirectMlsRetryLocked(
            chatId: chatId, peerUserId: peerUserId, waitingForKeys: true)
        }
      }
    }

    if VibeSecureSessions.shared.hasSession(chatId: chatId) {
      VibeSecureEstablishment.refreshPeerConfirmation(
        chatId: chatId, apiBase: apiBase, token: authHeaderTokenLocked(), completion: settled)
    } else {
      VibeSecureEstablishment.establishDirectMessage(
        chatId: chatId,
        peerUserId: peerUserId,
        myUserId: normalizedString(getConfigValueLocked("userId")),
        apiBase: apiBase,
        token: authHeaderTokenLocked(),
        completion: settled
      )
    }
  }

  private func scheduleDirectMlsRetryLocked(
    chatId: String,
    peerUserId: String,
    waitingForKeys: Bool
  ) {
    guard directMlsRetryWorkItemsByChat[chatId] == nil else { return }
    let delays = waitingForKeys
      ? Self.directMlsKeyRetryDelays : Self.directMlsConfirmationRetryDelays
    let attempt: Int
    if waitingForKeys {
      attempt = (directMlsKeyRetryAttemptsByChat[chatId] ?? 0) + 1
      guard attempt <= delays.count else { return }
      directMlsKeyRetryAttemptsByChat[chatId] = attempt
    } else {
      attempt = (directMlsConfirmationRetryAttemptsByChat[chatId] ?? 0) + 1
      directMlsConfirmationRetryAttemptsByChat[chatId] = attempt
    }
    let delay = delays[min(attempt - 1, delays.count - 1)]
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.directMlsRetryWorkItemsByChat.removeValue(forKey: chatId)
      guard !(self.pendingOutboundQueueByChat[chatId]?.isEmpty ?? true) else {
        self.cancelDirectMlsReadinessLocked(chatId: chatId, resetAttempts: true)
        return
      }
      if waitingForKeys {
        VibeSecureSessions.shared.clearPeerKeysUnavailable(chatId: chatId)
      }
      self.ensureDirectMlsReadinessLocked(chatId: chatId, peerUserId: peerUserId)
    }
    directMlsRetryWorkItemsByChat[chatId] = workItem
    queue.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  private func cancelDirectMlsReadinessLocked(chatId: String, resetAttempts: Bool) {
    directMlsRetryWorkItemsByChat.removeValue(forKey: chatId)?.cancel()
    directMlsReadinessInFlightChatIds.remove(chatId)
    guard resetAttempts else { return }
    directMlsKeyRetryAttemptsByChat.removeValue(forKey: chatId)
    directMlsConfirmationRetryAttemptsByChat.removeValue(forKey: chatId)
  }

  private func queuedDraftMlsPeerUserIdLocked(chatId: String) -> String? {
    guard let messageId = pendingOutboundQueueByChat[chatId]?.first,
      let draft = pendingOutboundDraftsByMessageId[messageId],
      (draft["__requiresConfirmedMls"] as? Bool) == true
    else { return nil }
    return normalizedUpper(draft["peerUserId"] ?? draft["peer_user_id"])
  }

  private func establishDirectMlsOnOpenLocked(chatId: String) {
    guard chatId != "saved_messages",
      let peerUserId = normalizedUpper(chatPeerUserIdsByChatId[chatId]),
      UUID(uuidString: peerUserId) != nil,
      !isVolatileBridgeAgentChatLocked(chatId: chatId, peerUserId: peerUserId),
      let me = normalizedUpper(getConfigValueLocked("userId")),
      me != peerUserId, me < peerUserId,
      !VibeSecureSessions.shared.hasSession(chatId: chatId),
      let apiBase = apiBaseURLLocked()
    else { return }
    VibeSecureEstablishment.establishDirectMessage(
      chatId: chatId, peerUserId: peerUserId, myUserId: me,
      apiBase: apiBase, token: authHeaderTokenLocked()
    ) { _ in }
  }

  private func resumeDirectMlsReadinessLocked(newlyOnlineUserIds: Set<String>) {
    guard !newlyOnlineUserIds.isEmpty else { return }
    for (chatId, messageIds) in pendingOutboundQueueByChat {
      guard let messageId = messageIds.first,
        let draft = pendingOutboundDraftsByMessageId[messageId],
        (draft["__requiresConfirmedMls"] as? Bool) == true,
        let peerUserId = normalizedUpper(draft["peerUserId"] ?? draft["peer_user_id"]),
        newlyOnlineUserIds.contains(peerUserId)
      else { continue }
      directMlsRetryWorkItemsByChat.removeValue(forKey: chatId)?.cancel()
      VibeSecureSessions.shared.clearPeerKeysUnavailable(chatId: chatId)
      ensureDirectMlsReadinessLocked(chatId: chatId, peerUserId: peerUserId)
    }
  }

  private func ensureMlsProvisionedLocked(trigger: String, force: Bool = false) {
    let now = Int64(nowMs())
    if !force, mlsProvisionedAtMs != 0, now - mlsProvisionedAtMs < 60_000 { return }
    guard let apiBase = apiBaseURLLocked() else { return }
    let token = authHeaderTokenLocked()
    mlsProvisionedAtMs = now
    VibeSecureEstablishment.ensureKeyPackagesPublished(apiBase: apiBase, token: token)
    VibeSecureEstablishment.drainPendingWelcomes(
      apiBase: apiBase, token: token, selfUserId: currentUserIdLocked()
    ) {
      [weak self] joinedChatIds in
      guard let self = self, !joinedChatIds.isEmpty else { return }
      self.queue.async {
        for chatId in joinedChatIds {
          self.scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "mls_welcome_drained")
          VibeTimelinePreparedStore.shared.invalidate(chatId: chatId)
          self.loadChatHistoryIfNeededLocked(chatId: chatId, force: true)
        }
      }
    }
  }

  private func apiBaseURLLocked() -> URL? {
    if let configured = normalizedString(
      getConfigValueLocked("apiBaseUrl") ?? getConfigValueLocked("baseUrl")),
      let url = URL(string: configured)
    {
      return url
    }
    guard
      let socketUrl = normalizedString(
        getConfigValueLocked("socketUrl") ?? getConfigValueLocked("url")),
      var components = URLComponents(string: socketUrl)
    else { return nil }
    if components.scheme == "wss" { components.scheme = "https" }
    if components.scheme == "ws" { components.scheme = "http" }
    if components.path.hasSuffix("/socket") {
      components.path = String(components.path.dropLast("/socket".count))
    }
    return components.url
  }

  private func originString(from base: URL) -> String? {
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.path = ""
    components.query = nil
    components.fragment = nil
    guard let url = components.url else { return nil }
    return url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private func sanitizeOpenURLString(_ raw: String) -> String {
    let trimmed =
      raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

    return
      trimmed
      .replacingOccurrences(
        of: #"^https?:\/\/\[(https?:\/\/[^\]]+)\](\/.*)?$"#,
        with: "$1$2",
        options: .regularExpression
      )
      .replacingOccurrences(
        of: #"^\[(https?:\/\/[^\]]+)\](\/.*)?$"#,
        with: "$1$2",
        options: .regularExpression
      )
      .replacingOccurrences(of: "https://https://", with: "https://")
      .replacingOccurrences(of: "http://http://", with: "http://")
  }

  private func resolveURLForOpenLocked(_ raw: String?) -> String? {
    guard let raw = normalizedString(raw), !raw.isEmpty else { return nil }
    let sanitized = sanitizeOpenURLString(raw)
    guard !sanitized.isEmpty else { return nil }

    if let url = URL(string: sanitized), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https" || scheme == "file"
    {
      return url.absoluteString
    }

    if sanitized.hasPrefix("/uploads/") || sanitized.hasPrefix("uploads/"),
      let base = apiBaseURLLocked(),
      let origin = originString(from: base)
    {
      let path = sanitized.hasPrefix("/") ? sanitized : "/" + sanitized
      return origin + path
    }

    if sanitized.hasPrefix("/"), let base = apiBaseURLLocked(),
      let origin = originString(from: base)
    {
      return origin + sanitized
    }

    return sanitized
  }

  private func authHeaderTokenLocked() -> String? {
    normalizedString(getConfigValueLocked("authToken") ?? getConfigValueLocked("token"))
  }

  private func chatHistoryCacheUserIdLocked() -> String? {
    normalizedString(configuredUserId)
      ?? normalizedString(getConfigValueLocked("userId") ?? getConfigValueLocked("myUserId"))
  }

  private func chatHistoryCacheKeyLocked(chatId: String) -> String? {
    guard let userId = chatHistoryCacheUserIdLocked(), !chatId.isEmpty else { return nil }
    return "\(chatHistoryCacheKeyPrefix).\(cacheKeyComponent(userId)).\(cacheKeyComponent(chatId))"
  }

  private static let persistPrepareTailRows = 400

  func prepareTimelinesAfterLaunch(chatIds: [String]) {
    let bounded = Array(
      chatIds
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .prefix(3))
    guard !bounded.isEmpty else { return }
    queue.async { [weak self] in
      guard let self, let userId = self.chatHistoryCacheUserIdLocked() else { return }
      for chatId in bounded {
        guard !VibeTimelinePreparedStore.shared.hasCoverage(chatId: chatId) else { continue }
        let rows: [[String: Any]] = self.messageStore.recentMessagePayloads(
          userId: userId, chatId: chatId, limit: Self.persistPrepareTailRows
        ).compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        guard !rows.isEmpty else { continue }
        VibeTimelinePreparedStore.shared.prepareAsync(
          chatId: chatId, rawRows: rows, reason: "launch", scope: .page)
      }
    }
  }

  private func isTransientStreamRow(_ row: [String: Any]) -> Bool {
    guard let id = messageId(fromRow: row) else { return false }
    return id.hasPrefix("stream-") || id.hasPrefix("lan-") || id.hasPrefix("bridge-")
  }

  // MARK: - Agent/bridge DM volatility (empty on cold launch, live only within a run)

  private func loadAgentDMChatIdsIfNeededLocked() {
    guard !agentDMChatIdsLoaded else { return }
    agentDMChatIdsLoaded = true
    if let stored = UserDefaults.standard.array(forKey: Self.agentDMChatIdsDefaultsKey)
      as? [String]
    {
      agentDMChatIdsPersisted = Set(stored.filter { !$0.isEmpty })
    }
  }

  private func isAgentDMForPersistenceLocked(chatId: String) -> Bool {
    guard !chatId.isEmpty else { return false }
    loadAgentDMChatIdsIfNeededLocked()
    if agentDMChatIdsPersisted.contains(chatId) { return true }
    return isVolatileBridgeAgentChatLocked(chatId: chatId)
  }

  private func markAgentDMChatForPersistenceLocked(chatId: String) {
    guard !chatId.isEmpty else { return }
    loadAgentDMChatIdsIfNeededLocked()
    guard !agentDMChatIdsPersisted.contains(chatId) else { return }
    agentDMChatIdsPersisted.insert(chatId)
    UserDefaults.standard.set(
      Array(agentDMChatIdsPersisted), forKey: Self.agentDMChatIdsDefaultsKey)
  }

  private func purgeAgentDMDurableStoreIfNeededLocked(chatId: String) {
    guard !chatId.isEmpty, !agentDMStorePurgedChats.contains(chatId) else { return }
    agentDMStorePurgedChats.insert(chatId)
    clearCachedHistoryRowsLocked(chatId: chatId)
    guard let existing = historyRowsByChat[chatId], !existing.isEmpty else { return }
    let removedIds = existing.compactMap { messageId(fromRow: $0) }
    historyRowsByChat.removeValue(forKey: chatId)
    historyFullyLoadedChats.remove(chatId)
    historyRowsRestoredFromCacheChats.remove(chatId)
    NSLog(
      "[HistoryStore] agent-DM drop in-memory chat=%@ rows=%d (volatile-per-session)",
      String(chatId.prefix(12)), existing.count)
    postChatDeltaLocked(
      chatId: chatId, inserted: [], updated: [], deleted: removedIds, source: "agentDMPurge")
  }

  private func restoreCachedHistoryRowsLocked(chatId: String) -> Bool {
    guard !chatId.isEmpty else { return false }
    if isAgentDMForPersistenceLocked(chatId: chatId) {
      purgeAgentDMDurableStoreIfNeededLocked(chatId: chatId)
      return false
    }
    if let existing = historyRowsByChat[chatId], !existing.isEmpty,
      historyFullyLoadedChats.contains(chatId)
    {
      return true
    }
    if historyRestoreMissChats.contains(chatId) { return false }
    guard let userId = chatHistoryCacheUserIdLocked() else { return false }
    var decodedRows: [[String: Any]] = messageStore.recentMessagePayloads(
      userId: userId, chatId: chatId, limit: chatHistoryCacheRowLimit
    ).compactMap { payload in
      (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    }
    if decodedRows.isEmpty {
      guard let cacheKey = chatHistoryCacheKeyLocked(chatId: chatId),
        let data = UserDefaults.standard.data(forKey: cacheKey),
        let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
        let legacyRows = object as? [[String: Any]]
      else {
        NSLog(
          "[HistoryStore] restore MISS chat=%@ — SQLite holds 0 rows and no legacy blob",
          String(chatId.prefix(12)))
        historyRestoreMissChats.insert(chatId)
        return false
      }
      decodedRows = legacyRows
      persistHistoryRowsToStoreLocked(chatId: chatId, rows: legacyRows)
      UserDefaults.standard.removeObject(forKey: cacheKey)
    }
    let rows = decodedRows.filter { !isTransientStreamRow($0) }
    guard !rows.isEmpty else {
      NSLog(
        "[HistoryStore] restore DROPPED chat=%@ — all %d stored rows are transient (stream-/lan-)",
        String(chatId.prefix(12)), decodedRows.count)
      historyRestoreMissChats.insert(chatId)
      return false
    }

    let dedup = dedupContentIdenticalRestoredRows(rows)
    let restoredRows = dedup.rows
    if !dedup.droppedIds.isEmpty {
      if let userId = chatHistoryCacheUserIdLocked() {
        messageStore.deleteMessages(
          userId: userId, chatId: chatId, messageIds: dedup.droppedIds)
        VibeCoreStoreBridge.tombstoneMessages(
          userId: userId, chatId: chatId, messageIds: dedup.droppedIds)
        VibeCoreStoreBridge.repairChat(
          userId: userId, chatId: chatId, reason: "restore-dedup")
      }
      flagTranscriptHealedForRasterInvalidation(chatId: chatId)
      NSLog(
        "[HistoryStore] restore DEDUP chat=%@ dropped=%d twin rows (same content+ms, different id)",
        String(chatId.prefix(12)), dedup.droppedIds.count)
    }
    historyRowsByChat[chatId] = restoredRows
    historyFullyLoadedChats.insert(chatId)
    historyRowsRestoredFromCacheChats.insert(chatId)
    feedCoreRawFramesLocked(
      chatId: chatId,
      rawMessages: restoredRows.compactMap { $0["message"] as? [String: Any] },
      source: .storeRestore)
    NSLog(
      "[HistoryStore] restore HIT chat=%@ rows=%d (painted from local store, no network)",
      String(chatId.prefix(12)), restoredRows.count)
    appendJournalLocked(
      event: "native-chat-history-cache-restore",
      payload: ["chatId": chatId, "rows": restoredRows.count])
    VibeDebugLog.log(
      "[ChatEngine] restored cached chat history chatId=%@ rows=%d",
      String(chatId.prefix(12)),
      restoredRows.count
    )
    return true
  }

  private func dedupContentIdenticalRestoredRows(
    _ rows: [[String: Any]]
  ) -> (rows: [[String: Any]], droppedIds: [String]) {
    guard rows.count > 1 else { return (rows, []) }
    var bestIndexBySignature: [String: Int] = [:]
    var droppedIndices: Set<Int> = []
    var droppedIds: [String] = []
    for (index, row) in rows.enumerated() {
      guard let id = messageId(fromRow: row),
        let message = row["message"] as? [String: Any],
        (message["isAgentMessage"] as? Bool) != true
      else { continue }
      let ts = messageTimestampMs(fromRow: row)
      guard ts > 0 else { continue }
      let signature = [
        String(ts),
        normalizedString(message["type"]) ?? "text",
        normalizedUpper(message["fromId"]) ?? "",
        (message["isMe"] as? Bool) == true ? "me" : "peer",
        normalizedString(message["text"]) ?? "",
        normalizedString(message["mediaUrl"]) ?? "",
        normalizedString(message["fileName"]) ?? "",
      ].joined(separator: "|")
      guard let keptIndex = bestIndexBySignature[signature] else {
        bestIndexBySignature[signature] = index
        continue
      }
      let keptMessage = rows[keptIndex]["message"] as? [String: Any] ?? [:]
      let keptId = messageId(fromRow: rows[keptIndex]) ?? ""
      let currentWins =
        message.count != keptMessage.count ? message.count > keptMessage.count : id > keptId
      if currentWins {
        droppedIndices.insert(keptIndex)
        droppedIds.append(keptId)
        bestIndexBySignature[signature] = index
      } else {
        droppedIndices.insert(index)
        droppedIds.append(id)
      }
    }
    guard !droppedIndices.isEmpty else { return (rows, []) }
    let kept = rows.enumerated().compactMap { droppedIndices.contains($0.offset) ? nil : $0.element }
    return (kept, droppedIds)
  }

  private func storeCachedHistoryRowsLocked(chatId: String, rows: [[String: Any]]) {
    guard !chatId.isEmpty, !rows.isEmpty else { return }
    let stored = persistHistoryRowsToStoreLocked(chatId: chatId, rows: rows)
    guard stored > 0 else { return }
    appendJournalLocked(
      event: "native-chat-history-cache-store",
      payload: ["chatId": chatId, "rows": stored])
    VibeDebugLog.log(
      "[ChatEngine] stored cached chat history chatId=%@ rows=%d",
      String(chatId.prefix(12)),
      stored
    )
  }

  @discardableResult
  private func persistHistoryRowsToStoreLocked(
    chatId: String,
    rows: [[String: Any]],
    skipPrune: Bool = false
  ) -> Int {
    guard let userId = chatHistoryCacheUserIdLocked(), messageStore.isAvailable else { return 0 }
    if isAgentDMForPersistenceLocked(chatId: chatId) {
      markAgentDMChatForPersistenceLocked(chatId: chatId)
      return 0
    }
    var entries: [(messageId: String, ts: Int64, payload: Data)] = []
    entries.reserveCapacity(rows.count)
    var durableRows: [[String: Any]] = []
    durableRows.reserveCapacity(rows.count)
    for row in rows {
      guard !isTransientStreamRow(row),
        let messageId = messageId(fromRow: row),
        JSONSerialization.isValidJSONObject(row),
        let payload = try? JSONSerialization.data(withJSONObject: row, options: [])
      else { continue }
      entries.append((messageId, messageTimestampMs(fromRow: row), payload))
      durableRows.append(row)
    }
    guard !entries.isEmpty else { return 0 }
    messageStore.upsertMessages(userId: userId, chatId: chatId, entries: entries)
    VibeTimelinePreparedStore.shared.prepareAsync(
      chatId: chatId,
      rawRows: Array(durableRows.suffix(Self.persistPrepareTailRows)),
      reason: "persist", scope: .page)
    historyRestoreMissChats.remove(chatId)
    let locallyDeletedIds = deletedMessageIdsByChat[chatId] ?? []
    if !locallyDeletedIds.isEmpty {
      messageStore.deleteMessages(
        userId: userId, chatId: chatId, messageIds: Array(locallyDeletedIds))
    }
    if !skipPrune {
      messageStore.pruneChat(userId: userId, chatId: chatId)
    }
    VibeCoreStoreBridge.backfillChat(userId: userId, chatId: chatId)
    let mirroredEntries =
      locallyDeletedIds.isEmpty
      ? entries
      : entries.filter { !locallyDeletedIds.contains($0.messageId) }
    if !locallyDeletedIds.isEmpty, mirroredEntries.count != entries.count {
      let resurrected = entries.map(\.messageId).filter { locallyDeletedIds.contains($0) }
      VibeCoreStoreBridge.tombstoneMessages(
        userId: userId, chatId: chatId, messageIds: resurrected)
    }
    VibeCoreStoreBridge.mirrorRows(
      userId: userId, chatId: chatId, entries: mirroredEntries,
      keepNewest: skipPrune ? 0 : UInt32(ChatMessageStore.prunedChatRowLimit))
    VibeCoreStoreBridge.verifyAgainstLegacy(userId: userId, chatId: chatId)
    return entries.count
  }

  private func reconcileStoreAgainstCanonicalLocked(chatId: String, canonicalIds: Set<String>) {
    guard !canonicalIds.isEmpty, let userId = chatHistoryCacheUserIdLocked(),
      messageStore.isAvailable
    else { return }
    let stored = messageStore.messageIdsWithTimestamps(userId: userId, chatId: chatId)
    guard !stored.isEmpty else { return }
    let liveIds = Set(liveMessageRowsByChat[chatId]?.keys.map { $0 } ?? [])
    let pendingIds = Set(pendingOutboundDraftsByMessageId.keys)
    let recencyFloorTs = Int64(nowMs()) - Int64(5 * 60 * 1000)
    let ghostIds = stored.filter { entry in
      !canonicalIds.contains(entry.messageId)
        && !liveIds.contains(entry.messageId)
        && !pendingIds.contains(entry.messageId)
        && entry.ts < recencyFloorTs
    }.map(\.messageId)
    guard !ghostIds.isEmpty else { return }
    messageStore.deleteMessages(userId: userId, chatId: chatId, messageIds: ghostIds)
    VibeCoreStoreBridge.tombstoneMessages(
      userId: userId, chatId: chatId, messageIds: ghostIds)
    VibeCoreStoreBridge.repairChat(
      userId: userId, chatId: chatId, reason: "canonical-reconcile")
    flagTranscriptHealedForRasterInvalidation(chatId: chatId)
    NSLog(
      "[HistoryStore] reconcile chat=%@ purged=%d of %d stored (ids absent from the canonical transcript)",
      String(chatId.prefix(12)), ghostIds.count, stored.count)
  }

  private func flagTranscriptHealedForRasterInvalidation(chatId: String) {
    let key = "VibeReopenRasterHealedChats"
    let defaults = UserDefaults.standard
    var ids = defaults.stringArray(forKey: key) ?? []
    guard !ids.contains(chatId) else { return }
    ids.append(chatId)
    defaults.set(ids, forKey: key)
  }

  func purgeLocalStateForAccountChange(previousUserId: String) {
    let previous = previousUserId.trimmingCharacters(in: .whitespacesAndNewlines)
    publishedChatRowsLock.lock()
    publishedChatRowsByChat.removeAll()
    publishedChatRowsLock.unlock()

    queue.async { [weak self] in
      guard let self = self else { return }
      self.historyRowsByChat.removeAll()
      self.liveMessageRowsByChat.removeAll()
      self.historyFullyLoadedChats.removeAll()
      self.historyRowsRestoredFromCacheChats.removeAll()
      self.agentDMChatIdsPersisted.removeAll()
      UserDefaults.standard.removeObject(forKey: Self.agentDMChatIdsDefaultsKey)
      guard !previous.isEmpty else { return }
      self.messageStore.deleteAllForUser(userId: previous)
      VibeCoreStoreBridge.purgeUser(userId: previous)
      NSLog("[AccountBoundary] purged local chat state for %@", String(previous.prefix(8)))
    }
  }

  private func clearCachedHistoryRowsLocked(chatId: String) {
    if let userId = chatHistoryCacheUserIdLocked() {
      let before = messageStore.messageCount(userId: userId, chatId: chatId)
      if before > 0 {
        NSLog(
          "[HistoryStore] WIPE chat=%@ — deleting %d stored rows",
          String(chatId.prefix(12)), before)
      }
      messageStore.deleteChat(userId: userId, chatId: chatId)
      VibeCoreStoreBridge.clearChat(userId: userId, chatId: chatId)
    }
    VibeTimelinePreparedStore.shared.invalidate(chatId: chatId)
    ChatListView.clearWarmTranscriptSnapshot(chatId: chatId)
    guard let cacheKey = chatHistoryCacheKeyLocked(chatId: chatId) else { return }
    UserDefaults.standard.removeObject(forKey: cacheKey)
    UserDefaults.standard.synchronize()
  }

  // MARK: - Agent-bridge DM row persistence

  private func volatileBridgeRowsCacheDir() -> URL? {
    guard
      let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first
    else { return nil }
    return base.appendingPathComponent("VibeBridgeRows", isDirectory: true)
  }

  private func purgeVolatileBridgeRowsCacheOnLaunchLocked() {
    guard let dir = volatileBridgeRowsCacheDir() else { return }
    if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
      for name in files {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
      }
      appendJournalLocked(
        event: "bridge-rows-cache-purge-launch", payload: ["files": files.count])
    }
  }

  private func volatileBridgeRowsCacheURL(chatId: String) -> URL? {
    guard let dir = volatileBridgeRowsCacheDir() else { return nil }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("rows-\(cacheKeyComponent(chatId)).json")
  }

  private func scheduleVolatileBridgeRowsStoreLocked(chatId: String) {
    guard !chatId.isEmpty, volatileBridgeRowsStoreTimers[chatId] == nil,
      isVolatileBridgeAgentChatLocked(chatId: chatId)
    else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.volatileBridgeRowsStoreTimers.removeValue(forKey: chatId)
      self.storeVolatileBridgeRowsLocked(chatId: chatId)
    }
    volatileBridgeRowsStoreTimers[chatId] = work
    queue.asyncAfter(deadline: .now() + 1.5, execute: work)
  }

  private func storeVolatileBridgeRowsLocked(chatId: String) {
    guard let url = volatileBridgeRowsCacheURL(chatId: chatId) else { return }
    let perChat = liveMessageRowsByChat[chatId] ?? [:]
    var settled: [String: [String: Any]] = [:]
    for (rowMessageId, row) in perChat {
      if rowMessageId.hasPrefix("stream-") { continue }
      let message = row["message"] as? [String: Any]
      let metaStreaming = (message?["metadata"] as? [String: Any])?["isStreaming"] as? Bool
      let topStreaming = message?["isStreaming"] as? Bool
      if metaStreaming == true || topStreaming == true { continue }
      settled[rowMessageId] = row
    }
    guard !settled.isEmpty else { return }
    if settled.count > 80 {
      let newest = settled.sorted {
        messageTimestampMs(fromRow: $0.value) < messageTimestampMs(fromRow: $1.value)
      }.suffix(80)
      settled = Dictionary(uniqueKeysWithValues: Array(newest))
    }
    guard JSONSerialization.isValidJSONObject(settled),
      let data = try? JSONSerialization.data(withJSONObject: settled, options: [])
    else {
      appendJournalLocked(
        event: "bridge-rows-cache-skip",
        payload: ["chatId": chatId, "reason": "invalid_json"])
      return
    }
    try? data.write(to: url, options: [.atomic])
    appendJournalLocked(
      event: "bridge-rows-cache-store",
      payload: ["chatId": chatId, "rows": settled.count])
  }

  private func restoreVolatileBridgeRowsIfNeededLocked(chatId: String) {
    guard !chatId.isEmpty, !volatileBridgeRowsRestoredChats.contains(chatId) else { return }
    volatileBridgeRowsRestoredChats.insert(chatId)
    guard let url = volatileBridgeRowsCacheURL(chatId: chatId),
      let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data, options: []),
      let cached = object as? [String: [String: Any]],
      !cached.isEmpty
    else { return }
    var perChat = liveMessageRowsByChat[chatId] ?? [:]
    let deletedIds = deletedMessageIdsByChat[chatId] ?? []
    var seeded = 0
    var seededIds: [String] = []
    var settledOnRestore = 0
    for (rowMessageId, row) in cached {
      guard perChat[rowMessageId] == nil, !deletedIds.contains(rowMessageId) else { continue }
      if isStaleStreamingAgentRowLocked(row, minStaleMs: 3 * 60 * 1000) {
        perChat[rowMessageId] = terminalizedStaleAgentRowLocked(row)
        settledOnRestore += 1
      } else {
        perChat[rowMessageId] = row
      }
      seeded += 1
      seededIds.append(rowMessageId)
    }
    if settledOnRestore > 0 {
      NSLog(
        "[TeamSettle] restore-settle chat=%@ settled=%d of %d",
        String(chatId.prefix(12)), settledOnRestore, seeded)
    }
    guard seeded > 0 else { return }
    liveMessageRowsByChat[chatId] = perChat
    NSLog(
      "[ChatEngine] bridge-rows cache seeded chatId=%@ rows=%d",
      String(chatId.prefix(12)), seeded)
    appendJournalLocked(
      event: "bridge-rows-cache-restore",
      payload: ["chatId": chatId, "rows": seeded])
    postChatDeltaLocked(
      chatId: chatId, inserted: seededIds.sorted(), updated: [], deleted: [],
      source: "bridgeRestore")
  }

  private func clearVolatileBridgeHistoryLocked(chatId: String, reason: String) {
    guard !chatId.isEmpty else { return }
    agentBridgeHistoryByChat.removeValue(forKey: chatId)
    let listPrefix = "\(chatId)|"
    agentBridgeHistoryListByChatProvider = agentBridgeHistoryListByChatProvider.filter {
      !$0.key.hasPrefix(listPrefix)
    }
    pendingAgentBridgeHistoryRequestsByChat.removeValue(forKey: chatId)
    appendJournalLocked(
      event: "native-bridge-history-cleared",
      payload: ["chatId": chatId, "reason": reason]
    )
  }

  private func supervisorTeamRunIdForRowLocked(_ row: [String: Any]) -> String? {
    guard let message = row["message"] as? [String: Any],
      let metadata = message["metadata"] as? [String: Any]
    else { return nil }
    let runtime = (metadata["agentRuntime"] as? [String: Any]) ?? [:]
    guard let teamRunId = normalizedString(runtime["teamRunId"] ?? runtime["team_run_id"]),
      !teamRunId.isEmpty
    else { return nil }
    let teamMode = (normalizedString(runtime["teamMode"] ?? runtime["team_mode"]) ?? "").lowercased()
    let isSupervisor = teamMode == "supervisor" || teamMode == "group_supervisor"
    let hasWorkerStatus =
      ((metadata["teamWorkersStatus"] as? [[String: Any]])?.isEmpty == false)
      || ((runtime["teamWorkersStatus"] as? [[String: Any]])?.isEmpty == false)
    return (isSupervisor || hasWorkerStatus) ? teamRunId : nil
  }

  private func hasFinishedTeamCardLocked(chatId: String, teamRunId: String) -> Bool {
    guard !teamRunId.isEmpty else { return false }
    func finishedForRun(_ message: [String: Any]) -> Bool {
      guard let metadata = message["metadata"] as? [String: Any] else { return false }
      let runtime = (metadata["agentRuntime"] as? [String: Any]) ?? [:]
      guard normalizedString(runtime["teamRunId"] ?? runtime["team_run_id"]) == teamRunId
      else { return false }
      if let id = normalizedString(message["id"]),
        id.hasPrefix("stream-") || id.hasPrefix("lan-")
      {
        return false
      }
      let streaming =
        (message["isStreaming"] as? Bool) == true
        || (metadata["isStreaming"] as? Bool) == true
      return !streaming
    }
    if let perChat = liveMessageRowsByChat[chatId] {
      for (_, row) in perChat {
        if let message = row["message"] as? [String: Any], finishedForRun(message) {
          return true
        }
      }
    }
    for row in historyRowsByChat[chatId] ?? [] {
      if let message = row["message"] as? [String: Any], finishedForRun(message) {
        return true
      }
    }
    return false
  }

  private func clearSocketResetLiveRowsLocked() {
    VibeDebugLog.log(
      "[EmptyTrace] socketReset clearLiveRows — chats=%d (connection DID reset)",
      liveMessageRowsByChat.count)
    let previousLive = liveMessageRowsByChat
    var nextLive: [String: [String: [String: Any]]] = [:]
    for (chatId, perChat) in previousLive {
      if isVolatileBridgeAgentChatLocked(chatId: chatId) {
        nextLive[chatId] = perChat
        continue
      }
      let historyIds = Set((historyRowsByChat[chatId] ?? []).compactMap { messageId(fromRow: $0) })
      var kept: [String: [String: Any]] = [:]
      for (rowMessageId, row) in perChat {
        if rowMessageId.hasPrefix("stream-") {
          if let teamRunId = supervisorTeamRunIdForRowLocked(row),
            !hasFinishedTeamCardLocked(chatId: chatId, teamRunId: teamRunId)
          {
            kept[rowMessageId] = row
            VibeDebugLog.log(
              "[FirstMsg] socketReset preserving team lead row chatId=%@ run=%@",
              String(chatId.prefix(12)), String(teamRunId.prefix(8)))
          }
          continue
        }
        if historyIds.contains(rowMessageId) { continue }
        kept[rowMessageId] = row
      }
      if !kept.isEmpty {
        nextLive[chatId] = kept
        VibeDebugLog.log(
          "[FirstMsg] socketReset keeping %d live row(s) chatId=%@ (not in fetched history)",
          kept.count, String(chatId.prefix(12)))
      }
    }
    liveMessageRowsByChat = nextLive
    deletedMessageIdsByChat = deletedMessageIdsByChat.filter { chatId, _ in
      isVolatileBridgeAgentChatLocked(chatId: chatId)
        || liveMessageRowsByChat[chatId] != nil
        || historyRowsByChat[chatId] != nil
    }
    for (chatId, perChat) in previousLive {
      let remainingIds = Set(nextLive[chatId]?.keys ?? Dictionary<String, [String: Any]>().keys)
      let removedIds = Set(perChat.keys).subtracting(remainingIds).sorted()
      postChatDeltaLocked(
        chatId: chatId, inserted: [], updated: [], deleted: removedIds, source: "socketReset")
    }
  }

  private func cacheKeyComponent(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let mapped = trimmed.unicodeScalars.map { scalar -> Character in
      CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
    }
    let resolved = String(mapped)
    return resolved.isEmpty ? "default" : resolved
  }

  private func oldestHistoryBoundaryLocked(
    rows: [[String: Any]]
  ) -> (messageId: String, timestampMs: Int64)? {
    var oldest: (messageId: String, timestampMs: Int64)?
    for row in rows {
      guard let messageId = messageId(fromRow: row) else { continue }
      let timestampMs = messageTimestampMs(fromRow: row)
      if let current = oldest,
        current.timestampMs < timestampMs
          || (current.timestampMs == timestampMs && current.messageId <= messageId)
      {
        continue
      }
      oldest = (messageId, timestampMs)
    }
    return oldest
  }

  private func oldestHistoryBoundaryLocked(
    chatId: String
  ) -> (messageId: String, timestampMs: Int64)? {
    guard let rows = historyRowsByChat[chatId], !rows.isEmpty else { return nil }
    return oldestHistoryBoundaryLocked(rows: rows)
  }

  private func encodedHistoryCursorLocked(
    timestampMs: Int64,
    messageId: String
  ) -> String? {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: ["timestamp": timestampMs, "id": messageId], options: [.sortedKeys])
    else { return nil }
    return data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private func applyHistoryPaginationMetadataLocked(
    chatId: String,
    response: [String: Any],
    remoteRows: [[String: Any]]
  ) {
    if response.keys.contains("hasMore"), let hasMore = parseBooleanLike(response["hasMore"]) {
      historyHasMoreByChat[chatId] = hasMore
      if hasMore {
        historyOlderExhaustedChats.remove(chatId)
      } else {
        historyOlderExhaustedChats.insert(chatId)
      }
    }

    if response.keys.contains("nextCursor") {
      if let nextCursor = normalizedString(response["nextCursor"]) {
        historyNextCursorByChat[chatId] = nextCursor
        if let boundary = oldestHistoryBoundaryLocked(rows: remoteRows) {
          historyNextCursorBoundaryByChat[chatId] = boundary
        } else {
          historyNextCursorBoundaryByChat.removeValue(forKey: chatId)
        }
      } else {
        historyNextCursorByChat.removeValue(forKey: chatId)
        historyNextCursorBoundaryByChat.removeValue(forKey: chatId)
      }
    }
  }

  private func backfillNewestChatHistoryLocked(chatId: String, trigger: String) {
    guard historyRowsByChat[chatId] != nil else { return }
    guard chatId != "saved_messages",
      !isBuiltInAgentChatId(chatId),
      !isAgentDMForPersistenceLocked(chatId: chatId),
      !historyBackfillingChats.contains(chatId)
    else { return }
    let now = Int64(nowMs())
    if let last = historyBackfillAtMsByChat[chatId], now - last < 10_000 { return }
    guard let apiBase = apiBaseURLLocked(),
      normalizedString(getConfigValueLocked("userId")) != nil
    else { return }

    let baseMessageUrl = apiBase.appendingPathComponent("api").appendingPathComponent("chat")
      .appendingPathComponent(chatId).appendingPathComponent("messages")
    var urlComponents = URLComponents(url: baseMessageUrl, resolvingAgainstBaseURL: false)
    urlComponents?.queryItems = [
      URLQueryItem(name: "limit", value: "\(chatOlderHistoryFetchLimit)")
    ]
    guard let finalUrl = urlComponents?.url else { return }
    var request = URLRequest(url: finalUrl)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if let token = authHeaderTokenLocked(), !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    historyBackfillingChats.insert(chatId)
    historyBackfillAtMsByChat[chatId] = now
    NSLog(
      "[ChatEngine] backfillNewest START chatId=%@ trigger=%@",
      String(chatId.prefix(12)), trigger)

    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      self.queue.async {
        self.historyBackfillingChats.remove(chatId)
        guard error == nil,
          let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
          let data,
          let object = try? JSONSerialization.jsonObject(with: data)
        else {
          NSLog(
            "[ChatEngine] backfillNewest FAIL chatId=%@ trigger=%@ error=%@",
            String(chatId.prefix(12)), trigger,
            error?.localizedDescription
              ?? "http_\((response as? HTTPURLResponse)?.statusCode ?? -1)")
          return
        }
        let responseDict = object as? [String: Any]
        let messagesArray: [[String: Any]]
        if let array = object as? [[String: Any]] {
          messagesArray = array
        } else if let array = responseDict?["data"] as? [[String: Any]] {
          messagesArray = array
        } else if let array = responseDict?["messages"] as? [[String: Any]] {
          messagesArray = array
        } else {
          return
        }
        let remoteRows = self.buildHistoryRowsLocked(chatId: chatId, rawMessages: messagesArray)
          .filter { !self.isTransientStreamRow($0) }
        guard !remoteRows.isEmpty else { return }
        let (rows, delta) = self.ingestHistoryRowsLocked(chatId: chatId, remoteRows: remoteRows)
        self.historyRowsByChat[chatId] = rows
        _ = self.persistHistoryRowsToStoreLocked(chatId: chatId, rows: rows)
        let retiredLiveIds = self.retireLiveRowsSupersededByDurableLocked(
          chatId: chatId, durableRows: remoteRows)
        let changed =
          !delta.insertedIds.isEmpty || !delta.updatedIds.isEmpty || !delta.deletedIds.isEmpty
          || !retiredLiveIds.isEmpty
        NSLog(
          "[ChatEngine] backfillNewest OK chatId=%@ trigger=%@ fetched=%d ins=%d upd=%d retiredLive=%d",
          String(chatId.prefix(12)), trigger, remoteRows.count,
          delta.insertedIds.count, delta.updatedIds.count, retiredLiveIds.count)
        if !delta.insertedIds.isEmpty {
          let liveForChat = self.liveMessageRowsByChat[chatId] ?? [:]
          let durableById = Dictionary(
            remoteRows.compactMap { row -> (String, [String: Any])? in
              guard let mid = self.messageId(fromRow: row) else { return nil }
              return (mid, row)
            }, uniquingKeysWith: { _, last in last })
          let insDetail = delta.insertedIds.map { id -> String in
            let liveRow = liveForChat[id]
            let liveDup = liveRow != nil
            let liveTs = liveRow.map { self.messageTimestampMs(fromRow: $0) } ?? -1
            let durableTs = durableById[id].map { self.messageTimestampMs(fromRow: $0) } ?? -1
            let tsMoved = liveDup && liveTs != durableTs
            return
              "\(id.suffix(6)){live=\(liveDup ? "Y" : "N") ts=\(liveTs)->\(durableTs)\(tsMoved ? " MOVED" : "")}"
          }.joined(separator: ",")
          NSLog(
            "[BackfillReinsert] chatId=%@ ins=[%@] liveRows=%d",
            String(chatId.prefix(12)), insDetail, liveForChat.count)
        }
        self.appendJournalLocked(
          event: "native-chat-backfill-ok",
          payload: [
            "chatId": chatId, "trigger": trigger, "fetched": remoteRows.count,
            "inserted": delta.insertedIds.count, "retiredLive": retiredLiveIds.count,
          ])
        guard changed else { return }
        self.state["updatedAt"] = self.nowMs()
        self.postChangeLocked(
          reason: "chatRowsReloaded",
          userInfo: ["chatId": chatId, "state": self.statusSnapshotLocked()])
        self.postChatDeltaLocked(
          chatId: chatId,
          inserted: delta.insertedIds,
          updated: delta.updatedIds,
          deleted: delta.deletedIds + retiredLiveIds,
          source: "backfill")
      }
    }.resume()
  }

  private func retireLiveRowsSupersededByDurableLocked(
    chatId: String, durableRows: [[String: Any]]
  ) -> [String] {
    guard let perChat = liveMessageRowsByChat[chatId], !perChat.isEmpty else { return [] }
    var durableMessageIdByTaskId: [String: String] = [:]
    for row in durableRows {
      guard let mid = messageId(fromRow: row),
        let taskId = agentTaskIdFromRow(row), !taskId.isEmpty
      else { continue }
      durableMessageIdByTaskId[taskId] = mid
    }
    guard !durableMessageIdByTaskId.isEmpty else { return [] }
    var removedIds: [String] = []
    for (liveId, liveRow) in perChat {
      guard liveId.hasPrefix("stream-") || liveId.hasPrefix("lan-") else { continue }
      guard let liveTaskId = agentTaskIdFromRow(liveRow),
        let durableMessageId = durableMessageIdByTaskId[liveTaskId]
      else { continue }
      if let slotTs = agentStreamTimestampsByChat[chatId]?[liveId] {
        adoptAgentSettleSlotTsLocked(chatId: chatId, messageId: durableMessageId, slotTs: slotTs)
      }
      liveMessageRowsByChat[chatId]?.removeValue(forKey: liveId)
      removedIds.append(liveId)
      removeBridgeTaskTrackingLocked(chatId: chatId, taskId: liveTaskId)
      NSLog(
        "[ChatEngine] retireSupersededLive chatId=%@ live=%@ task=%@ durable=%@",
        String(chatId.suffix(12)), String(liveId.suffix(20)),
        String(liveTaskId.suffix(20)), String(durableMessageId.suffix(12)))
    }
    if liveMessageRowsByChat[chatId]?.isEmpty == true {
      liveMessageRowsByChat.removeValue(forKey: chatId)
    }
    if !removedIds.isEmpty, var perChatTimestamps = agentStreamTimestampsByChat[chatId] {
      for id in removedIds { perChatTimestamps.removeValue(forKey: id) }
      if perChatTimestamps.isEmpty {
        agentStreamTimestampsByChat.removeValue(forKey: chatId)
      } else {
        agentStreamTimestampsByChat[chatId] = perChatTimestamps
      }
    }
    return removedIds
  }

  private func agentTaskIdFromRow(_ row: [String: Any]) -> String? {
    guard let message = row["message"] as? [String: Any],
      let metadata = message["metadata"] as? [String: Any]
    else { return nil }
    let runtime = (metadata["agentRuntime"] as? [String: Any]) ?? [:]
    return normalizedString(
      runtime["taskId"] ?? runtime["task_id"]
        ?? metadata["agentTaskId"] ?? metadata["agent_task_id"])
  }

  private func loadOlderChatHistoryLocked(chatId: String) -> Bool {
    guard !historyLoadingOlderChats.contains(chatId), !historyLoadingChats.contains(chatId),
      chatId != "saved_messages",
      !isBuiltInAgentChatId(chatId),
      !isAgentDMForPersistenceLocked(chatId: chatId),
      !historyOlderExhaustedChats.contains(chatId),
      let boundary = oldestHistoryBoundaryLocked(chatId: chatId)
    else { return false }

    historyLoadingOlderChats.insert(chatId)
    if let userId = chatHistoryCacheUserIdLocked(), messageStore.isAvailable {
      let payloads = messageStore.olderMessagePayloads(
        userId: userId,
        chatId: chatId,
        beforeTs: boundary.timestampMs,
        beforeMessageId: boundary.messageId,
        limit: chatOlderHistoryFetchLimit
      )
      if !payloads.isEmpty {
        let olderRows = payloads.compactMap { payload in
          (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        }.filter { !isTransientStreamRow($0) }
        let existingCount = historyRowsByChat[chatId]?.count ?? 0
        feedCoreRawFramesLocked(
          chatId: chatId,
          rawMessages: olderRows.compactMap { $0["message"] as? [String: Any] },
          source: .storeRestore)
        let (rows, delta) = ingestHistoryRowsLocked(chatId: chatId, remoteRows: olderRows)
        historyRowsByChat[chatId] = rows
        historyLoadingOlderChats.remove(chatId)
        state["updatedAt"] = nowMs()
        let prependedCount = max(0, rows.count - existingCount)
        appendJournalLocked(
          event: "native-chat-older-history-load-ok",
          payload: [
            "chatId": chatId,
            "source": "store",
            "rows": prependedCount,
          ])
        NSLog(
          "[ChatEngine] loadOlderHistory chatId=%@ source=store rows=%d exhausted=N",
          String(chatId.prefix(12)), prependedCount)
        postChangeLocked(
          reason: "chatRowsReloaded",
          userInfo: [
            "chatId": chatId,
            "state": statusSnapshotLocked(),
            "prependedOlder": prependedCount,
          ])
        postChatDeltaLocked(
          chatId: chatId, inserted: delta.insertedIds, updated: delta.updatedIds,
          deleted: delta.deletedIds, source: "history")
        return true
      }
    }

    guard let apiBase = apiBaseURLLocked(),
      normalizedString(getConfigValueLocked("userId")) != nil
    else {
      historyLoadingOlderChats.remove(chatId)
      appendJournalLocked(
        event: "native-chat-older-history-skip",
        payload: ["chatId": chatId, "reason": "missing_config"])
      return false
    }

    let cursor: String?
    if let serverCursor = historyNextCursorByChat[chatId],
      let cursorBoundary = historyNextCursorBoundaryByChat[chatId],
      cursorBoundary.messageId == boundary.messageId,
      cursorBoundary.timestampMs == boundary.timestampMs
    {
      cursor = serverCursor
    } else {
      cursor = encodedHistoryCursorLocked(
        timestampMs: boundary.timestampMs, messageId: boundary.messageId)
    }
    guard let cursor else {
      historyLoadingOlderChats.remove(chatId)
      return false
    }

    let baseMessageUrl = apiBase.appendingPathComponent("api").appendingPathComponent("chat")
      .appendingPathComponent(chatId).appendingPathComponent("messages")
    var urlComponents = URLComponents(url: baseMessageUrl, resolvingAgainstBaseURL: false)
    urlComponents?.queryItems = [
      URLQueryItem(name: "limit", value: "\(chatOlderHistoryFetchLimit)"),
      URLQueryItem(name: "before", value: cursor),
    ]
    guard let finalUrl = urlComponents?.url else {
      historyLoadingOlderChats.remove(chatId)
      return false
    }
    var request = URLRequest(url: finalUrl)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if let token = authHeaderTokenLocked(), !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    let fetchStartMs = nowMs()
    NSLog(
      "[ChatEngine] loadOlderHistory START chatId=%@ limit=%d",
      String(chatId.prefix(12)), chatOlderHistoryFetchLimit)
    appendJournalLocked(
      event: "native-chat-older-history-load-start",
      payload: ["chatId": chatId, "source": "network"])

    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      self.queue.async {
        let durationMs = self.nowMs() - fetchStartMs
        self.historyLoadingOlderChats.remove(chatId)
        if let error {
          NSLog(
            "[ChatEngine] loadOlderHistory FAIL chatId=%@ duration=%lldms error=%@",
            String(chatId.prefix(12)), durationMs, error.localizedDescription)
          self.appendJournalLocked(
            event: "native-chat-older-history-load-error",
            payload: ["chatId": chatId, "error": error.localizedDescription])
          self.postChangeLocked(
            reason: "engineError",
            userInfo: ["state": self.statusSnapshotLocked(), "error": error.localizedDescription])
          return
        }
        guard let http = response as? HTTPURLResponse else {
          NSLog(
            "[ChatEngine] loadOlderHistory FAIL chatId=%@ duration=%lldms error=invalid_response",
            String(chatId.prefix(12)), durationMs)
          self.appendJournalLocked(
            event: "native-chat-older-history-load-error",
            payload: ["chatId": chatId, "error": "invalid_response"])
          return
        }
        guard (200...299).contains(http.statusCode), let data else {
          NSLog(
            "[ChatEngine] loadOlderHistory FAIL chatId=%@ duration=%lldms status=%d",
            String(chatId.prefix(12)), durationMs, http.statusCode)
          self.appendJournalLocked(
            event: "native-chat-older-history-load-error",
            payload: ["chatId": chatId, "status": http.statusCode])
          return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
          self.appendJournalLocked(
            event: "native-chat-older-history-load-error",
            payload: ["chatId": chatId, "error": "invalid_json_expected_messages_array"])
          return
        }

        let responseDict = object as? [String: Any]
        let messagesArray: [[String: Any]]
        if let array = object as? [[String: Any]] {
          messagesArray = array
        } else if let array = responseDict?["data"] as? [[String: Any]] {
          messagesArray = array
        } else if let array = responseDict?["messages"] as? [[String: Any]] {
          messagesArray = array
        } else {
          self.appendJournalLocked(
            event: "native-chat-older-history-load-error",
            payload: ["chatId": chatId, "error": "invalid_json_expected_messages_array"])
          return
        }

        let olderRows = self.buildHistoryRowsLocked(chatId: chatId, rawMessages: messagesArray)
          .filter { !self.isTransientStreamRow($0) }
        if let responseDict {
          self.applyHistoryPaginationMetadataLocked(
            chatId: chatId, response: responseDict, remoteRows: olderRows)
        }
        guard !olderRows.isEmpty else {
          self.historyHasMoreByChat[chatId] = false
          self.historyNextCursorByChat.removeValue(forKey: chatId)
          self.historyNextCursorBoundaryByChat.removeValue(forKey: chatId)
          self.historyOlderExhaustedChats.insert(chatId)
          NSLog(
            "[ChatEngine] loadOlderHistory chatId=%@ source=network rows=0 exhausted=Y",
            String(chatId.prefix(12)))
          self.appendJournalLocked(
            event: "native-chat-older-history-load-ok",
            payload: ["chatId": chatId, "source": "network", "rows": 0, "exhausted": true])
          return
        }

        let existingCount = self.historyRowsByChat[chatId]?.count ?? 0
        let coreFrames = self.coreProjectedFramesLocked(
          chatId: chatId, rawMessages: messagesArray, rows: olderRows)
        self.feedCoreRawFramesLocked(
          chatId: chatId, rawMessages: coreFrames, source: .historyPage)
        let (rows, delta) = self.ingestHistoryRowsLocked(chatId: chatId, remoteRows: olderRows)
        self.historyRowsByChat[chatId] = rows
        _ = self.persistHistoryRowsToStoreLocked(
          chatId: chatId, rows: olderRows, skipPrune: true)
        self.state["updatedAt"] = self.nowMs()
        let prependedCount = max(0, rows.count - existingCount)
        let exhausted = self.historyOlderExhaustedChats.contains(chatId)
        NSLog(
          "[ChatEngine] loadOlderHistory chatId=%@ source=network rows=%d exhausted=%@",
          String(chatId.prefix(12)), prependedCount, exhausted ? "Y" : "N")
        self.appendJournalLocked(
          event: "native-chat-older-history-load-ok",
          payload: [
            "chatId": chatId,
            "source": "network",
            "rows": prependedCount,
            "exhausted": exhausted,
          ])
        self.postChangeLocked(
          reason: "chatRowsReloaded",
          userInfo: [
            "chatId": chatId,
            "state": self.statusSnapshotLocked(),
            "prependedOlder": prependedCount,
          ])
        self.postChatDeltaLocked(
          chatId: chatId, inserted: delta.insertedIds, updated: delta.updatedIds,
          deleted: delta.deletedIds, source: "history")
      }
    }.resume()
    return true
  }

  private func historyNetworkSyncDefaultsKey(userId: String, chatId: String) -> String {
    "chat.history.lastNetworkSyncMs.\(userId).\(chatId)"
  }

  private func lastHistoryNetworkSyncAtLocked(chatId: String) -> Int? {
    if let cached = historyLastNetworkSyncAtByChat[chatId] {
      return cached
    }
    guard let userId = chatHistoryCacheUserIdLocked() else { return nil }
    let value = UserDefaults.standard.object(
      forKey: historyNetworkSyncDefaultsKey(userId: userId, chatId: chatId)) as? NSNumber
    let ms = value?.intValue
    if let ms, ms > 0 {
      historyLastNetworkSyncAtByChat[chatId] = ms
    }
    return ms
  }

  private func markHistoryNetworkSyncedLocked(chatId: String) {
    let ms = Int(nowMs())
    historyLastNetworkSyncAtByChat[chatId] = ms
    guard let userId = chatHistoryCacheUserIdLocked() else { return }
    UserDefaults.standard.set(
      ms, forKey: historyNetworkSyncDefaultsKey(userId: userId, chatId: chatId))
  }

  private func isHistoryNetworkSyncFreshLocked(chatId: String) -> Bool {
    guard let last = lastHistoryNetworkSyncAtLocked(chatId: chatId), last > 0 else {
      return false
    }
    return (Int(nowMs()) - last) < historyRevalidationTTLMs
  }

  private func loadChatHistoryIfNeededLocked(chatId: String, force: Bool = false) {
    guard !chatId.isEmpty else { return }
    guard !isBuiltInAgentChatId(chatId), !isAgentDMForPersistenceLocked(chatId: chatId) else {
      historyLoadingChats.remove(chatId)
      if isAgentDMForPersistenceLocked(chatId: chatId) {
        markAgentDMChatForPersistenceLocked(chatId: chatId)
      }
      appendJournalLocked(
        event: "native-chat-history-skip",
        payload: ["chatId": chatId, "reason": "agent_surface"]
      )
      VibeDebugLog.log("[ChatEngine] loadChatHistory SKIP chatId=%@ reason=agent_surface", chatId)
      return
    }
    if historyLoadingChats.contains(chatId) || historyLoadingOlderChats.contains(chatId) { return }
    if !force, historyFullyLoadedChats.contains(chatId) {
      if !historyRowsRestoredFromCacheChats.contains(chatId) {
        return
      }
      if isHistoryNetworkSyncFreshLocked(chatId: chatId) {
        historyRowsRestoredFromCacheChats.remove(chatId)
        NSLog(
          "[ChatEngine] loadChatHistory SKIP chatId=%@ reason=restored_fresh_ttl",
          String(chatId.prefix(12)))
        return
      }
    }
    let isBridgeText = isBridgeTextModeLocked()
    let apiBase = apiBaseURLLocked()
    let bridgeURL = bridgeURLLocked("/bridge/v1/chat/history")
    guard let userId = normalizedString(getConfigValueLocked("userId")),
      (isBridgeText ? bridgeURL != nil : apiBase != nil)
    else {
      NSLog(
        "[ChatEngine] loadChatHistory SKIP chatId=%@ reason=missing_config",
        String(chatId.prefix(12)))
      appendJournalLocked(
        event: "native-chat-history-skip",
        payload: [
          "chatId": chatId,
          "reason": "missing_config",
        ])
      return
    }

    let isSavedMessages = chatId == "saved_messages"

    historyLoadingChats.insert(chatId)
    let token = authHeaderTokenLocked()
    let finalUrl: URL
    var request: URLRequest
    if isBridgeText, let bridgeURL {
      finalUrl = bridgeURL
      request = URLRequest(url: finalUrl)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try? JSONSerialization.data(
        withJSONObject: [
          "chatId": chatId,
          "userId": userId,
          "limit": chatHistoryFetchLimit,
          "savedMessages": isSavedMessages,
        ],
        options: []
      )
    } else if isSavedMessages, let apiBase {
      finalUrl = apiBase.appendingPathComponent("api").appendingPathComponent("saved_messages")
        .appendingPathComponent(userId)
      request = URLRequest(url: finalUrl)
      request.httpMethod = "GET"
    } else if let apiBase {
      let baseMessageUrl = apiBase.appendingPathComponent("api").appendingPathComponent("chat")
        .appendingPathComponent(chatId).appendingPathComponent("messages")
      var urlComponents = URLComponents(url: baseMessageUrl, resolvingAgainstBaseURL: false)
      urlComponents?.queryItems = [URLQueryItem(name: "limit", value: "\(chatHistoryFetchLimit)")]
      finalUrl = urlComponents?.url ?? baseMessageUrl
      request = URLRequest(url: finalUrl)
      request.httpMethod = "GET"
    } else {
      historyLoadingChats.remove(chatId)
      return
    }
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if let token, !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    let fetchStartMs = self.nowMs()
    VibeDebugLog.log(
      "[ChatEngine] loadChatHistory START chatId=%@ limit=%d url=%@",
      String(chatId.prefix(12)),
      chatHistoryFetchLimit,
      request.url?.absoluteString ?? "nil")
    appendJournalLocked(event: "native-chat-history-load-start", payload: ["chatId": chatId])

    let session = ChatPhoenixClient.makePinnedURLSession()
    session.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      self.queue.async {
        let durationMs = self.nowMs() - fetchStartMs
        self.historyLoadingChats.remove(chatId)
        if let error {
          NSLog(
            "[ChatEngine] loadChatHistory FAIL chatId=%@ duration=%lldms error=%@",
            String(chatId.prefix(12)), durationMs, error.localizedDescription)
          self.appendJournalLocked(
            event: "native-chat-history-load-error",
            payload: [
              "chatId": chatId,
              "error": error.localizedDescription,
            ])
          let snapshot = self.statusSnapshotLocked()
          self.postChangeLocked(
            reason: "engineError",
            userInfo: ["state": snapshot, "error": error.localizedDescription])
          return
        }
        guard let http = response as? HTTPURLResponse else {
          NSLog(
            "[ChatEngine] loadChatHistory FAIL chatId=%@ duration=%lldms error=invalid_response",
            String(chatId.prefix(12)), durationMs)
          self.appendJournalLocked(
            event: "native-chat-history-load-error",
            payload: [
              "chatId": chatId,
              "error": "invalid_response",
            ])
          return
        }
        guard (200...299).contains(http.statusCode), let data else {
          NSLog(
            "[ChatEngine] loadChatHistory FAIL chatId=%@ duration=%lldms status=%d",
            String(chatId.prefix(12)), durationMs, http.statusCode)
          self.appendJournalLocked(
            event: "native-chat-history-load-error",
            payload: [
              "chatId": chatId,
              "status": http.statusCode,
            ])
          return
        }
        VibeDebugLog.log(
          "[ChatEngine] loadChatHistory OK chatId=%@ duration=%lldms bytes=%d",
          String(chatId.prefix(12)),
          durationMs, data.count)
        if isSavedMessages {
          self.applySavedMessagesHistoryResponseLocked(data: data)
        } else {
          self.applyChatHistoryResponseLocked(chatId: chatId, data: data)
        }
      }
    }.resume()
  }

  private func coreProjectedFramesLocked(
    chatId: String, rawMessages: [[String: Any]], rows: [[String: Any]]
  ) -> [[String: Any]] {
    var messagesById: [String: [String: Any]] = [:]
    for row in rows {
      guard let message = row["message"] as? [String: Any],
        let messageId = normalizedString(message["id"] ?? message["message_id"])
      else { continue }
      messagesById[messageId] = message
    }

    return rawMessages.map { raw in
      let rawIdValue =
        chatId == "saved_messages"
        ? raw["original_message_id"] ?? raw["originalMessageId"] ?? raw["id"]
          ?? raw["message_id"]
        : raw["id"] ?? raw["message_id"]
      guard let messageId = normalizedString(rawIdValue),
        let message = messagesById[messageId]
      else {
        noteCoreFrameWithoutPlaintextLocked(
          chatId: chatId, frame: raw, messageId: normalizedString(rawIdValue),
          projected: false, isMine: false, decryptFailed: false)
        return raw
      }

      var frame = raw
      for (key, value) in message where key != "encryptedContent" {
        frame[key] = value
      }
      noteCoreFrameWithoutPlaintextLocked(
        chatId: chatId, frame: frame, messageId: messageId, projected: true,
        isMine: (message["isMe"] as? Bool) == true,
        decryptFailed: (message["decryptionFailed"] as? Bool) == true)
      if let metadata = message["metadata"] as? [String: Any] {
        for key in [
          "mediaKey", "waveform", "width", "height", "thumbnailBase64", "fileSize",
          "viewOnce", "mediaTtlSeconds", "contact",
        ] {
          if let value = metadata[key] { frame[key] = value }
        }
      }
      return frame
    }
  }

  private func noteCoreFrameWithoutPlaintextLocked(
    chatId: String, frame: [String: Any], messageId: String?, projected: Bool, isMine: Bool,
    decryptFailed: Bool
  ) {
    guard let messageId, !messageId.isEmpty else { return }
    guard normalizedString(frame["encryptedContent"] ?? frame["encrypted_content"]) != nil,
      normalizedString(frame["text"]) == nil,
      normalizedString(frame["plainContent"] ?? frame["plain_content"]) == nil,
      normalizedString(frame["caption"]) == nil,
      normalizedString(frame["mediaUrl"] ?? frame["media_url"]) == nil,
      ChatEngine.cryptoLogOnce("core-frame", messageId: messageId)
    else { return }
    var line = chatEngineCryptoMeta(chatId: chatId, messageId: messageId, isMine: isMine)
    line["stage"] = projected ? "core-ingest" : "core-ingest-unmatched"
    line["env"] =
      VibeSecureSessions.isMlsEnvelope(
        normalizedString(frame["encryptedContent"] ?? frame["encrypted_content"]))
      ? "mls" : "hybrid"
    line["decryptFailed"] = decryptFailed ? "Y" : "N"
    VibeLog.warning("core frame carries no plaintext", category: "crypto", metadata: line)
  }

  private func feedCoreRawFramesLocked(
    chatId: String, rawMessages: [[String: Any]], source: VibeFfiSource
  ) {
    guard !rawMessages.isEmpty else { return }
    guard VibeTimelineUserDefaultsFeatureFlags.isDirectMessageRenderPathEnabled() else { return }
    guard let core = VibeCoreBridge.sharedCore(ownUserId: currentUserIdLocked() ?? "") else {
      return
    }
    guard JSONSerialization.isValidJSONObject(rawMessages),
      let json = try? JSONSerialization.data(withJSONObject: rawMessages)
    else {
      VibeLog.warning(
        "core ingest skipped — page is not JSON-serializable", category: "core",
        metadata: ["chat": String(chatId.prefix(12)), "rows": String(rawMessages.count)])
      return
    }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    do {
      try core.ingestFrames(
        chatId: chatId, jsonArray: json, source: source, receivedAtMs: now)
      NSLog(
        "[VibeCore] fed chat=%@ frames=%d source=%@",
        String(chatId.prefix(12)), rawMessages.count, String(describing: source))
    } catch {
      VibeLog.warning(
        "core ingest rejected", category: "core",
        metadata: [
          "chat": String(chatId.prefix(12)), "error": String(describing: error),
        ])
    }
  }

  private func feedCoreDeleteLocked(chatId: String, messageId: String) {
    guard VibeTimelineUserDefaultsFeatureFlags.isDirectMessageRenderPathEnabled() else { return }
    guard let core = VibeCoreBridge.sharedCore(ownUserId: currentUserIdLocked() ?? "") else {
      return
    }
    try? core.deleteMessage(
      chatId: chatId, messageId: messageId, forEveryone: true,
      tombstoneMs: Int64(Date().timeIntervalSince1970 * 1000))
  }

  // MARK: - Repairing a missed clear

  private var appliedMessagesClearedAtByChat: [String: Int64] = [:]

  func applyRemoteMessagesClearedAt(chatId: String, clearedAtMs: Int64) {
    guard !chatId.isEmpty, clearedAtMs > 0 else { return }
    queue.async { [weak self] in
      self?.applyRemoteMessagesClearedAtLocked(chatId: chatId, clearedAtMs: clearedAtMs)
    }
  }

  private func applyRemoteMessagesClearedAtLocked(chatId: String, clearedAtMs: Int64) {
    guard (appliedMessagesClearedAtByChat[chatId] ?? Int64.min) < clearedAtMs else { return }
    appliedMessagesClearedAtByChat[chatId] = clearedAtMs

    var droppedFromStore = 0
    if let userId = chatHistoryCacheUserIdLocked() {
      let stale = messageStore.messageIdsWithTimestamps(userId: userId, chatId: chatId)
        .filter { $0.ts <= clearedAtMs }
        .map(\.messageId)
      if !stale.isEmpty {
        messageStore.deleteMessages(userId: userId, chatId: chatId, messageIds: stale)
        droppedFromStore = stale.count
      }
    }

    let historyBefore = historyRowsByChat[chatId]?.count ?? 0
    if let rows = historyRowsByChat[chatId] {
      historyRowsByChat[chatId] = rows.filter { messageTimestampMs(fromRow: $0) > clearedAtMs }
    }
    let liveBefore = liveMessageRowsByChat[chatId]?.count ?? 0
    if let live = liveMessageRowsByChat[chatId] {
      liveMessageRowsByChat[chatId] = live.filter {
        messageTimestampMs(fromRow: $0.value) > clearedAtMs
      }
    }
    let droppedFromMemory =
      (historyBefore - (historyRowsByChat[chatId]?.count ?? 0))
      + (liveBefore - (liveMessageRowsByChat[chatId]?.count ?? 0))

    if let core = VibeCoreBridge.sharedCore(ownUserId: currentUserIdLocked() ?? "") {
      try? core.clearChat(
        chatId: chatId, beforeTsMs: clearedAtMs &+ 1, clearedAtMs: clearedAtMs)
    }

    guard droppedFromStore > 0 || droppedFromMemory > 0 else { return }

    VibeTimelinePreparedStore.shared.invalidate(chatId: chatId)
    ChatListView.clearWarmTranscriptSnapshot(chatId: chatId)

    VibeLog.notice(
      "repaired a missed remote clear",
      category: "engine",
      metadata: [
        "chat": String(chatId.prefix(12)),
        "clearedAtMs": String(clearedAtMs),
        "droppedStore": String(droppedFromStore),
        "droppedMemory": String(droppedFromMemory),
      ])
    appendJournalLocked(
      event: "native-chat-clear-repair",
      payload: ["chatId": chatId, "clearedAtMs": clearedAtMs, "dropped": droppedFromStore])
    state["updatedAt"] = nowMs()
    postChangeLocked(reason: "chatRowsReloaded", userInfo: ["chatId": chatId])
    postChangeLocked(reason: "chatCleared", userInfo: ["chatId": chatId])
  }

  private func feedCoreClearChatLocked(chatId: String) {
    guard let core = VibeCoreBridge.sharedCore(ownUserId: currentUserIdLocked() ?? "") else {
      return
    }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    do {
      try core.clearChat(chatId: chatId, beforeTsMs: nil, clearedAtMs: now)
      NSLog("[VibeCore] clear chat=%@", String(chatId.prefix(12)))
    } catch {
      VibeLog.warning(
        "core clear rejected", category: "core",
        metadata: [
          "chat": String(chatId.prefix(12)), "error": String(describing: error),
        ])
    }
  }

  private func applyChatHistoryResponseLocked(chatId: String, data: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: data) else {
      appendJournalLocked(
        event: "native-chat-history-load-error",
        payload: [
          "chatId": chatId,
          "error": "invalid_json_expected_messages_array",
        ])
      return
    }

    let messagesArray: [[String: Any]]
    if let array = object as? [[String: Any]] {
      messagesArray = array
    } else if let dict = object as? [String: Any], let array = dict["data"] as? [[String: Any]] {
      messagesArray = array
    } else if let dict = object as? [String: Any], let array = dict["messages"] as? [[String: Any]]
    {
      messagesArray = array
    } else {
      appendJournalLocked(
        event: "native-chat-history-load-error",
        payload: [
          "chatId": chatId,
          "error": "invalid_json_expected_messages_array",
        ])
      return
    }

    let remoteRows = buildHistoryRowsLocked(chatId: chatId, rawMessages: messagesArray)
    let coreFrames = coreProjectedFramesLocked(
      chatId: chatId, rawMessages: messagesArray, rows: remoteRows)
    feedCoreRawFramesLocked(chatId: chatId, rawMessages: coreFrames, source: .historyPage)
    if let response = object as? [String: Any] {
      applyHistoryPaginationMetadataLocked(
        chatId: chatId, response: response, remoteRows: remoteRows)
    }
    let existingRows = historyRowsByChat[chatId] ?? []
    let existingRowsCount = existingRows.count
    let liveRowsCount = liveMessageRowsByChat[chatId]?.count ?? 0
    let (rows, delta) = ingestHistoryRowsLocked(chatId: chatId, remoteRows: remoteRows)
    let isUnchangedRefetch = !existingRows.isEmpty && (rows as NSArray).isEqual(to: existingRows)
    var adoptedFromStore = false
    if rows.isEmpty, existingRows.isEmpty {
      historyRowsByChat.removeValue(forKey: chatId)
      historyFullyLoadedChats.remove(chatId)
      adoptedFromStore = restoreCachedHistoryRowsLocked(chatId: chatId)
      if adoptedFromStore {
        NSLog(
          "[HistoryStore] empty-fetch chat=%@ — repainted %d rows from the local store",
          String(chatId.prefix(12)), historyRowsByChat[chatId]?.count ?? 0)
      }
    }
    if !adoptedFromStore {
      if !rows.isEmpty || existingRows.isEmpty {
        historyRowsByChat[chatId] = rows
      }
      historyFullyLoadedChats.insert(chatId)
      historyRowsRestoredFromCacheChats.remove(chatId)
    }
    markHistoryNetworkSyncedLocked(chatId: chatId)
    storeMergedChatHistoryIfLoadedLocked(chatId: chatId)
    state["updatedAt"] = nowMs()
    appendJournalLocked(
      event: "native-chat-history-load-ok",
      payload: [
        "chatId": chatId,
        "rows": rows.count,
        "remoteRows": remoteRows.count,
        "existingRows": existingRowsCount,
        "liveRows": liveRowsCount,
        "messages": messagesArray.count,
      ])
    let storedRowCount =
      chatHistoryCacheUserIdLocked().map {
        messageStore.messageCount(userId: $0, chatId: chatId)
      } ?? -1
    NSLog(
      "[ChatEngine] loadChatHistory MERGE chatId=%@ messages=%d remoteRows=%d existingRows=%d liveRows=%d mergedRows=%d store=%d unchanged=%@",
      String(chatId.prefix(12)),
      messagesArray.count,
      remoteRows.count,
      existingRowsCount,
      liveRowsCount,
      historyRowsByChat[chatId]?.count ?? rows.count,
      storedRowCount,
      isUnchangedRefetch ? "Y" : "N"
    )
    scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "history_loaded")
    guard !isUnchangedRefetch else { return }
    let snapshot = statusSnapshotLocked()
    postChangeLocked(reason: "chatRowsReloaded", userInfo: ["chatId": chatId, "state": snapshot])
    postChatDeltaLocked(
      chatId: chatId,
      inserted: delta.insertedIds,
      updated: delta.updatedIds,
      deleted: delta.deletedIds,
      source: "history")
  }

  private func applySavedMessagesHistoryResponseLocked(data: Data) {
    let chatId = "saved_messages"
    let rawItems = parseSavedMessagesServerItems(data)
    guard !rawItems.isEmpty else {
      appendJournalLocked(
        event: "native-chat-history-load-error",
        payload: [
          "chatId": chatId,
          "error": "empty_saved_messages_response",
        ])
      cachedSavedMessagesResponse = []
      if (historyRowsByChat[chatId] ?? []).isEmpty {
        historyRowsByChat.removeValue(forKey: chatId)
        historyFullyLoadedChats.remove(chatId)
        if !restoreCachedHistoryRowsLocked(chatId: chatId) {
          historyRowsByChat[chatId] = []
          historyFullyLoadedChats.insert(chatId)
          historyRowsRestoredFromCacheChats.remove(chatId)
        }
      }
      let snapshot = statusSnapshotLocked()
      postChangeLocked(reason: "chatRowsReloaded", userInfo: ["chatId": chatId, "state": snapshot])
      return
    }
    let normalized = normalizeSavedMessagesLocked(rawItems)
    cachedSavedMessagesResponse = normalized
    let previousRows = historyRowsByChat[chatId] ?? []
    let rows = buildHistoryRowsLocked(chatId: chatId, rawMessages: normalized)
    historyRowsByChat[chatId] = rows
    historyFullyLoadedChats.insert(chatId)
    historyRowsRestoredFromCacheChats.remove(chatId)
    markHistoryNetworkSyncedLocked(chatId: chatId)
    storeMergedChatHistoryIfLoadedLocked(chatId: chatId)
    reconcileStoreAgainstCanonicalLocked(
      chatId: chatId,
      canonicalIds: Set(rows.compactMap { messageId(fromRow: $0) }))
    state["updatedAt"] = nowMs()
    appendJournalLocked(
      event: "native-chat-history-load-ok",
      payload: [
        "chatId": chatId,
        "rows": rows.count,
        "messages": rawItems.count,
      ])
    scheduleReplayQueuedOutboundLocked(chatId: chatId, trigger: "history_loaded")
    let snapshot = statusSnapshotLocked()
    postChangeLocked(reason: "chatRowsReloaded", userInfo: ["chatId": chatId, "state": snapshot])
    let previousById = Dictionary(
      uniqueKeysWithValues: previousRows.compactMap { row in
        messageId(fromRow: row).map { ($0, row) }
      })
    let rowsById = Dictionary(
      uniqueKeysWithValues: rows.compactMap { row in
        messageId(fromRow: row).map { ($0, row) }
      })
    let previousIds = Set(previousById.keys)
    let ids = Set(rowsById.keys)
    let updatedIds = ids.intersection(previousIds).filter { id in
      guard let previous = previousById[id], let row = rowsById[id] else { return false }
      return !(row as NSDictionary).isEqual(to: previous)
    }.sorted()
    postChatDeltaLocked(
      chatId: chatId,
      inserted: ids.subtracting(previousIds).sorted(),
      updated: updatedIds,
      deleted: previousIds.subtracting(ids).sorted(),
      source: "savedMessages")
  }

  private func buildHistoryRowsLocked(chatId: String, rawMessages: [[String: Any]], allowMlsDecryption: Bool = true) -> [[String:
    Any]]
  {
    let sortedMessages = rawMessages.sorted { lhs, rhs in
      transcriptOrderPrecedes(
        lhsTs: transcriptTimestampMs(lhs), lhsId: rawMessageIdForOrdering(lhs, chatId: chatId),
        rhsTs: transcriptTimestampMs(rhs), rhsId: rawMessageIdForOrdering(rhs, chatId: chatId))
    }
    let rows: [[String: Any]] = sortedMessages.compactMap { (raw: [String: Any]) -> [String: Any]? in
      let preferredId =
        chatId == "saved_messages"
        ? raw["original_message_id"] ?? raw["originalMessageId"] ?? raw["id"] ?? raw["message_id"]
        : raw["id"] ?? raw["message_id"]
      guard let messageId = normalizedString(preferredId) else { return nil }
      let fromId = normalizedString(raw["fromId"] ?? raw["from_id"])
      let type = normalizedString(raw["type"]) ?? "text"
      let parsedTimestampMs = transcriptTimestampMs(raw)
      if parsedTimestampMs == nil {
        noteSynthesizedTimestamp(chatId: chatId, messageId: messageId, raw: raw)
      }
      let timestampMs = parsedTimestampMs ?? Int64(nowMs())
      let encryptedContent = normalizedString(raw["encryptedContent"] ?? raw["encrypted_content"])
      let plaintextFallback = normalizedString(raw["plaintext"] ?? raw["text"]) ?? ""
      let serverStatus = normalizedString(raw["status"])?.lowercased()
      let editedAt = parseLongValue(raw["editedAt"] ?? raw["edited_at"])
      let isEdited = ((raw["isEdited"] as? Bool) == true) || editedAt != nil
      let rawMediaUrl = normalizedString(raw["mediaUrl"] ?? raw["media_url"])
        .map(durableMediaURLStringLocked)
      let rawFileName = normalizedString(raw["fileName"] ?? raw["file_name"])
      let rawMediaKey = normalizedString(raw["mediaKey"] ?? raw["media_key"])
      let rawMetadata = raw["metadata"] as? [String: Any]
      let derivedFileName = deriveFileNameFromURL(rawMediaUrl)
      let rawAgentId = firstNormalizedString(
        raw["agentId"], raw["agent_id"], rawMetadata?["agentId"], rawMetadata?["agent_id"])
      let rawAgentName = firstNormalizedString(
        raw["agentName"], raw["agent_name"], rawMetadata?["agentName"], rawMetadata?["agent_name"])
      let rawAgentUserId = firstNormalizedString(
        raw["agentUserId"], raw["agent_user_id"], rawMetadata?["agentUserId"],
        rawMetadata?["agent_user_id"])
      let rawAgentUsername = firstNormalizedString(
        raw["agentUsername"], raw["agent_username"], raw["agentHandle"], raw["agent_handle"],
        rawMetadata?["agentUsername"], rawMetadata?["agent_username"], rawMetadata?["agentHandle"],
        rawMetadata?["agent_handle"])

      let isMe = normalizedUpper(fromId) != nil && normalizedUpper(fromId) == currentUserIdLocked()
      let encryptedLooksHybrid = isLikelyHybridCiphertext(encryptedContent)
      let historyIsAgent =
        (raw["isAgentMessage"] as? Bool == true)
        || (raw["is_agent_message"] as? Bool == true)
        || (normalizedString(fromId)?.lowercased() == Self.agentUserId)
        || rawAgentId != nil
        || rawAgentName != nil
        || (rawMediaUrl?.lowercased().contains("/uploads/agent-docs/") == true)
        || (rawMediaUrl?.lowercased().contains("/api/agent/document/") == true)
      let agentPlainContent =
        normalizedString(raw["plainContent"] ?? raw["plain_content"])
        ?? normalizedString(raw["plaintext"])
        ?? encryptedContent
      let hadEncryptedContent = encryptedContent != nil && !encryptedContent!.isEmpty
      var historyDecryptionFailed = false
      var historyDecryptStage = "-"
      let decryptedFields: [String: Any] = {
        if historyIsAgent {
          if let agentPlainContent, !agentPlainContent.isEmpty {
            return ["text": agentPlainContent]
          }
          return [:]
        }

        if let encryptedContent, !encryptedContent.isEmpty {
          if VibeSecureSessions.isMlsEnvelope(encryptedContent) {
            if let mine = VibeSecureSessions.shared.ownPlaintext(
              messageId: messageId, envelope: encryptedContent)
            {
              return parseDecryptedMessagePayload(mine)
            }
            if isMe {
              if !plaintextFallback.isEmpty { return ["text": plaintextFallback] }
              return [:]
            }
            guard allowMlsDecryption else { return [:] }
            guard
              let opened = VibeSecureSessions.shared.open(
                chatId: chatId, envelope: encryptedContent, isMine: false, messageId: messageId)
            else {
              historyDecryptionFailed = true
              historyDecryptStage = "mls-open"
              if !plaintextFallback.isEmpty { return ["text": plaintextFallback] }
              guard VibeSecureSessions.shared.isUnrecoverable(messageId: messageId) else { return [:] }
              return [
                "text": "This message can't be shown on this device. Ask the sender to resend it.",
                "decryptFailed": true,
              ]
            }
            let parsed = parseDecryptedMessagePayload(opened)
            if !parsed.isEmpty { return parsed }
            historyDecryptionFailed = true
            historyDecryptStage = "mls-payload-empty"
            return plaintextFallback.isEmpty ? [:] : ["text": plaintextFallback]
          }
          if !encryptedLooksHybrid {
            return parseDecryptedMessagePayload(encryptedContent)
          }
          guard let privateKey = decryptPrivateKeyLocked() else {
            historyDecryptionFailed = true
            historyDecryptStage = "no-rsa-key"
            return plaintextFallback.isEmpty ? [:] : ["text": plaintextFallback]
          }
          let decrypted = chatEngineDecryptHybridMessage(
            privateKey: privateKey,
            ciphertext: encryptedContent,
            isMyMessage: isMe,
            chatId: chatId,
            messageId: messageId
          )
          if decrypted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            historyDecryptionFailed = true
            historyDecryptStage = "hybrid-open"
            return plaintextFallback.isEmpty ? [:] : ["text": plaintextFallback]
          }
          let parsed = parseDecryptedMessagePayload(decrypted)
          if !parsed.isEmpty { return parsed }
          historyDecryptionFailed = true
          historyDecryptStage = "hybrid-payload-empty"
        }
        return plaintextFallback.isEmpty ? [:] : ["text": plaintextFallback]
      }()
      if historyDecryptionFailed, ChatEngine.cryptoLogOnce("history-open", messageId: messageId) {
        var line = chatEngineCryptoMeta(chatId: chatId, messageId: messageId, isMine: isMe)
        line["stage"] = historyDecryptStage
        line["env"] =
          VibeSecureSessions.isMlsEnvelope(encryptedContent)
          ? "mls" : (encryptedLooksHybrid ? "hybrid" : "plain")
        line["type"] = type
        line["fallback"] = plaintextFallback.isEmpty ? "none" : String(plaintextFallback.count)
        line["wireMediaUrl"] = (rawMediaUrl?.isEmpty == false) ? "Y" : "N"
        VibeLog.error("history row failed to decrypt", category: "crypto", metadata: line)
      }
      var enrichedFields = decryptedFields
      if let rawMetadata, enrichedFields["metadata"] == nil {
        enrichedFields["metadata"] = rawMetadata
      }
      if let rawReplyToId = normalizedString(raw["replyToId"] ?? raw["reply_to_id"]),
        normalizedString(enrichedFields["replyToId"] ?? enrichedFields["reply_to_id"]) == nil
      {
        enrichedFields["replyToId"] = rawReplyToId
      }
      if let rawReplyPreview = raw["replyPreview"] ?? raw["reply_preview"],
        enrichedFields["replyPreview"] == nil,
        enrichedFields["reply_preview"] == nil
      {
        enrichedFields["replyPreview"] = rawReplyPreview
      }
      if let rawReplyPreviewTitle = normalizedString(
        raw["replyPreviewTitle"] ?? raw["reply_preview_title"] ?? raw["replyAuthorName"]
          ?? raw["reply_author_name"]),
        normalizedString(enrichedFields["replyPreviewTitle"] ?? enrichedFields["reply_preview_title"])
          == nil
      {
        enrichedFields["replyPreviewTitle"] = rawReplyPreviewTitle
      }
      if let rawReplyPreviewText = normalizedString(
        raw["replyPreviewText"] ?? raw["reply_preview_text"] ?? raw["replyText"]
          ?? raw["reply_text"]),
        normalizedString(enrichedFields["replyPreviewText"] ?? enrichedFields["reply_preview_text"])
          == nil
      {
        enrichedFields["replyPreviewText"] = rawReplyPreviewText
      }
      if let rawMediaUrl, !rawMediaUrl.isEmpty, normalizedString(enrichedFields["mediaUrl"]) == nil
      {
        enrichedFields["mediaUrl"] = rawMediaUrl
      }
      if let existing = normalizedString(enrichedFields["mediaUrl"]), isLocalMediaURI(existing) {
        if let rawMediaUrl, !rawMediaUrl.isEmpty, !isLocalMediaURI(rawMediaUrl) {
          enrichedFields["mediaUrl"] = rawMediaUrl
        } else if let meta = enrichedFields["metadata"] as? [String: Any],
          let remote = normalizedString(meta["mediaUrl"] ?? meta["media_url"]),
          !remote.isEmpty, !isLocalMediaURI(remote)
        {
          enrichedFields["mediaUrl"] = remote
        } else {
          enrichedFields.removeValue(forKey: "mediaUrl")
        }
      }
      if let rawMetadata {
        if normalizedString(enrichedFields["thumbnailBase64"]) == nil,
          let thumb = normalizedString(
            rawMetadata["thumbnailBase64"] ?? rawMetadata["thumbnail_base64"])
        {
          enrichedFields["thumbnailBase64"] = thumb
        }
        if (enrichedFields["attachmentThumbnailsB64"] as? [String])?.isEmpty != false,
          let thumbs = rawMetadata["attachmentThumbnailsB64"] as? [String], !thumbs.isEmpty
        {
          enrichedFields["attachmentThumbnailsB64"] = thumbs
          var meta = (enrichedFields["metadata"] as? [String: Any]) ?? [:]
          meta["attachmentThumbnailsB64"] = thumbs
          enrichedFields["metadata"] = meta
        }
      }
      let resolvedMedia = normalizedString(enrichedFields["mediaUrl"])
      let hasThumb =
        normalizedString(enrichedFields["thumbnailBase64"]) != nil
        || ((enrichedFields["attachmentThumbnailsB64"] as? [String])?.isEmpty == false)
        || ((rawMetadata?["thumbnailBase64"] as? String)?.isEmpty == false)
      if normalizedString(enrichedFields["mediaKey"]) == nil {
        let keyFromRaw = rawMediaKey
        let keyFromMeta = normalizedString(
          rawMetadata?["mediaKey"] ?? rawMetadata?["media_key"])
        if let key = keyFromRaw ?? keyFromMeta, !key.isEmpty {
          enrichedFields["mediaKey"] = key
        }
      }
      let fileNameForRow =
        rawFileName
        ?? ((normalizedString(type)?.lowercased() == "file") ? derivedFileName : nil)
      if let fileNameForRow, !fileNameForRow.isEmpty,
        normalizedString(enrichedFields["fileName"]) == nil
      {
        enrichedFields["fileName"] = fileNameForRow
      }
      if enrichedFields["width"] == nil,
        let rawWidth = parseDoubleValue(rawMetadata?["width"] ?? rawMetadata?["media_width"])
      {
        enrichedFields["width"] = rawWidth
      }
      if enrichedFields["height"] == nil,
        let rawHeight = parseDoubleValue(rawMetadata?["height"] ?? rawMetadata?["media_height"])
      {
        enrichedFields["height"] = rawHeight
      }
      var resolvedType = type
      if (resolvedType == "text" || resolvedType.isEmpty),
        (resolvedMedia != nil && !(resolvedMedia?.isEmpty ?? true)) || hasThumb
      {
        resolvedType = "image"
      }
      var row = buildLiveRowPayloadLocked(
        chatId: chatId,
        messageId: messageId,
        fromId: fromId,
        type: resolvedType,
        timestampMs: timestampMs,
        encryptedContent: encryptedContent,
        decryptedFields: enrichedFields,
        forceEdited: isEdited,
        forceEditedAt: editedAt
      )
      if historyIsAgent, var message = row["message"] as? [String: Any] {
        message["isAgentMessage"] = true
        message["isMe"] = false
        if let rawAgentId { message["agentId"] = rawAgentId }
        if let agentUserId = rawAgentUserId ?? fromId {
          message["agentUserId"] = agentUserId
        }
        if let username = rawAgentUsername {
          message["agentUsername"] = username.trimmingCharacters(
            in: CharacterSet(charactersIn: "@"))
        }
        if let rawAgentName { message["agentName"] = rawAgentName }
        if let agentPlainContent, !agentPlainContent.isEmpty {
          message["plainContent"] = agentPlainContent
          message["text"] = agentPlainContent
        }
        row["message"] = message
      }
      if var message = row["message"] as? [String: Any] {
        if let serverStatus { message["status"] = serverStatus }
        if let reactions = raw["reactions"] as? [[String: Any]] {
          message["reactions"] = reactions
        }
        if let viewCount = parseLongValue(raw["viewCount"] ?? raw["view_count"]) {
          message["viewCount"] = viewCount
        }
        if let reactionEmoji = normalizedString(raw["reactionEmoji"] ?? raw["reaction_emoji"]) {
          message["reactionEmoji"] = reactionEmoji
        }
        if !historyIsAgent, hadEncryptedContent, historyDecryptionFailed,
          encryptedLooksHybrid || VibeSecureSessions.isMlsEnvelope(encryptedContent)
        {
          message["decryptionFailed"] = true
        }
        if !historyIsAgent, hadEncryptedContent, !historyDecryptionFailed,
          normalizedString(message["text"]) == nil,
          normalizedString(message["caption"]) == nil,
          normalizedString(message["mediaUrl"]) == nil,
          ChatEngine.cryptoLogOnce("history-empty-row", messageId: messageId)
        {
          var line = chatEngineCryptoMeta(chatId: chatId, messageId: messageId, isMine: isMe)
          line["stage"] = "history-row"
          line["env"] =
            VibeSecureSessions.isMlsEnvelope(encryptedContent)
            ? "mls" : (encryptedLooksHybrid ? "hybrid" : "plain")
          line["type"] = type
          line["fields"] = message.keys.sorted().prefix(8).joined(separator: ",")
          VibeLog.warning("opened but row has nothing to render", category: "crypto", metadata: line)
        }
        row["message"] = message
      }
      return row
    }
    return rowsByApplyingBubbleSequenceShapes(rows)
  }

  private func appendJournalLocked(event: String, payload: [String: Any]) {
    journalEntryCount = min(journalEntryCount + 1, 300)
    state["journalCount"] = journalEntryCount
    store.appendJournal([
      "event": event,
      "timestamp": nowMs(),
      "payload": sanitizeJournalPayload(makeJSONSafeMap(payload)),
    ])
  }

  private func sanitizeJournalPayload(_ payload: [String: Any]) -> [String: Any] {
    let sensitiveKeys: Set<String> = ["chatId", "messageId", "userId", "peerUserId", "fromId"]
    var out = payload
    for key in sensitiveKeys {
      if let value = out[key] as? String, value.count > 8 {
        out[key] = String(value.prefix(8)) + "..."
      }
    }
    return out
  }

  private func postChatDeltaLocked(
    chatId: String,
    inserted: [String],
    updated: [String],
    deleted: [String],
    source: String
  ) {
    guard !inserted.isEmpty || !updated.isEmpty || !deleted.isEmpty else { return }
    let generation = (chatIngestGenerationByChat[chatId] ?? 0) + 1
    chatIngestGenerationByChat[chatId] = generation
    postChangeLocked(
      reason: "chatDelta",
      userInfo: [
        "chatId": chatId,
        "generation": generation,
        "insertedIds": inserted,
        "updatedIds": updated,
        "deletedIds": deleted,
        "source": source,
        "state": statusSnapshotLocked(),
      ])
    NSLog(
      "[ChatDelta] %@ chat=%@ gen=%d ins=%d upd=%d del=%d",
      source, chatId, generation, inserted.count, updated.count, deleted.count)
  }

  private func publishUIMirrorLocked() {
    var progress: [String: ChatEngineAgentProgressSnapshot] = [:]
    progress.reserveCapacity(agentProgressByChatId.count)
    for (chatId, state) in agentProgressByChatId {
      progress[chatId] = ChatEngineAgentProgressSnapshot(
        label: state.label,
        tool: state.tool,
        status: state.status,
        updatedAtMs: state.updatedAtMs
      )
    }
    var pendingAsk: [String: [ChatEngineBridgeAskSnapshot]] = [:]
    for (requestId, payload) in agentBridgeAskByRequestId {
      guard !presentedAskRequestIds.contains(requestId) else { continue }
      guard let chatId = normalizedString(payload["chatId"]), !chatId.isEmpty else { continue }
      pendingAsk[chatId, default: []].append(
        ChatEngineBridgeAskSnapshot(
          requestId: requestId,
          chatId: chatId,
          kind: normalizedString(payload["kind"]) ?? "ask",
          provider: (normalizedString(payload["provider"]) ?? "").lowercased(),
          sessionId: normalizedString(payload["sessionId"] ?? payload["session_id"]) ?? "",
          resumedFromSessionId: normalizedString(
            payload["resumedFromSessionId"] ?? payload["resumed_from_session_id"]) ?? ""
        ))
    }
    for (chatId, prompts) in pendingAsk where prompts.count > 1 {
      pendingAsk[chatId] = prompts.sorted { $0.requestId < $1.requestId }
    }
    var askChatIds: Set<String> = []
    for payload in agentBridgeAskByRequestId.values {
      guard let chatId = normalizedString(payload["chatId"]), !chatId.isEmpty else { continue }
      askChatIds.insert(chatId)
    }
    var secureWait: Set<String> = []
    for (queuedChatId, ids) in pendingOutboundQueueByChat {
      guard
        ids.contains(where: {
          (pendingOutboundDraftsByMessageId[$0]?["__requiresConfirmedMls"] as? Bool) == true
        }),
        !VibeSecureSessions.shared.isPeerConfirmed(chatId: queuedChatId)
      else { continue }
      secureWait.insert(queuedChatId)
    }
    uiMirror.publish(
      typingByChatId: peerTypingUserIdsByChatId,
      agentProgressByChatId: progress,
      onlineUserIds: onlineUsers,
      lastSeenByUserId: lastSeenByUserId,
      pendingAskByChatId: pendingAsk,
      agentTurnRunningAtMsByChatId: agentTurnRunningAtMsByChatId,
      agentAskChatIds: askChatIds,
      receiptIndex: receiptIndex,
      localStatusIndex: localStatusIndex,
      secureWaitChatIds: secureWait
    )
    uiMirrorPublishes += 1
    if uiMirrorPublishes % Self.uiMirrorLogInterval == 1 {
      let counts = uiMirror.counts
      VibeLog.info(
        "ui mirror", category: "engine",
        metadata: [
          "reads": String(counts.mirrorReads),
          "fallback": String(counts.fallbackReads),
          "publishes": String(counts.publishes),
        ])
    }
  }

  private var uiMirrorPublishes = 0
  private static let uiMirrorLogInterval = 200

  private func postChangeLocked(reason: String, userInfo: [String: Any]) {
    publishUIMirrorLocked()
    var info = userInfo
    info["reason"] = reason
    info["timestamp"] = nowMs()
    if ["chatMessageInserted", "chatMessageChanged", "chatRowsReloaded"].contains(reason),
      let changedChatId = (userInfo["chatId"] as? String)?.trimmingCharacters(
        in: .whitespacesAndNewlines),
      !changedChatId.isEmpty
    {
      scheduleVolatileBridgeRowsStoreLocked(chatId: changedChatId)
    }
    if ["chatMessageInserted", "chatMessageChanged", "chatRowsReloaded", "presenceChanged"]
      .contains(reason)
    {
      let rawChatId =
        (info["chatId"] as? String) ??
        (info["chat_id"] as? String) ??
        ""
      let chatId =
        rawChatId.count > 12 ? String(rawChatId.prefix(12)) + "..." : rawChatId
      VibeDebugLog.print(
        "[ChatEngine] didChange reason=\(reason) chatId=\(chatId.isEmpty ? "<empty>" : chatId)"
      )
      chatEngineUITrace(
        "ChatEngine didChange reason=\(reason) chatId=\(chatId.isEmpty ? "<empty>" : chatId)"
      )
    }
    let notification = Notification(name: Self.didChangeNotification, object: self, userInfo: info)
    DispatchQueue.main.async {
      NotificationCenter.default.post(notification)
    }
  }

  private func nowMs() -> Int {
    Int(Date().timeIntervalSince1970 * 1000)
  }

  private func syncOnQueue<T>(
    _ work: () -> T,
    function: StaticString = #function,
    file: StaticString = #fileID,
    line: UInt = #line
  ) -> T {
    if DispatchQueue.getSpecific(key: queueSpecificKey) == queueSpecificValue {
      return work()
    }
    guard Thread.isMainThread else {
      return queue.sync(execute: work)
    }

    let start = CFAbsoluteTimeGetCurrent()
    let callSite = "\(function) (\(file):\(line))"
    let watchdog = DispatchSource.makeTimerSource(queue: ChatEngine.syncWatchdogQueue)
    watchdog.schedule(deadline: .now() + 0.75, repeating: 1.0)
    watchdog.setEventHandler {
      let blockedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
      NSLog(
        "[ChatEngine][MAIN-THREAD-HANG] main thread blocked %dms in syncOnQueue at %@",
        blockedMs, callSite)
    }
    watchdog.resume()
    let result = queue.sync(execute: work)
    watchdog.cancel()

    let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    if elapsedMs > 50 {
      let callers = Thread.callStackSymbols.dropFirst(2).prefix(8)
        .map { symbol -> String in
          let parts = symbol.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
          return parts.count >= 4 ? String(parts[3].prefix(70)) : symbol
        }
        .joined(separator: " ← ")
      NSLog(
        "[ChatEngine][MAIN-THREAD-SYNC-STALL] syncOnQueue blocked main thread for %dms at %@\n    via %@",
        elapsedMs, callSite, callers)
      VibeLog.error(
        "main-thread stall in syncOnQueue", category: "engine",
        metadata: ["ms": String(elapsedMs), "callSite": callSite])
    }
    return result
  }

  private func normalizedString(_ value: Any?) -> String? {
    if let str = value as? String {
      let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
      return t.isEmpty ? nil : t
    }
    if let n = value as? NSNumber {
      return n.stringValue
    }
    return nil
  }

  private func durableMediaURLStringLocked(_ value: String) -> String {
    guard
      let source = URLComponents(string: value),
      let host = source.host?.lowercased(),
      (host.hasSuffix(".r2.cloudflarestorage.com") || host == "media.vibegram.io"),
      let key = source.path.split(separator: "/").last.map(String.init),
      !key.isEmpty,
      var base = apiBaseURLLocked()
    else { return value }

    if base.path.lowercased().hasSuffix("/api") {
      base.deleteLastPathComponent()
    }
    return base
      .appendingPathComponent("api")
      .appendingPathComponent("media")
      .appendingPathComponent("o")
      .appendingPathComponent(key)
      .absoluteString
  }

  private func firstNormalizedString(_ values: Any?...) -> String? {
    for value in values {
      if let normalized = normalizedString(value) {
        return normalized
      }
    }
    return nil
  }

  private func parseBooleanLike(_ value: Any?) -> Bool? {
    switch value {
    case let bool as Bool:
      return bool
    case let str as String:
      let normalized = str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if ["1", "true", "yes", "on"].contains(normalized) {
        return true
      }
      if ["0", "false", "no", "off"].contains(normalized) {
        return false
      }
      return nil
    case let num as NSNumber:
      return num.boolValue
    default:
      return nil
    }
  }

  private func containsLinkCandidate(_ value: String?) -> Bool {
    guard let value, !value.isEmpty else { return false }
    let lower = value.lowercased()
    return lower.contains("http://") || lower.contains("https://") || lower.contains("www.")
  }

  private func normalizedUpper(_ value: Any?) -> String? {
    normalizedString(value)?.uppercased()
  }

  private func makeJSONSafeMap(_ payload: [String: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (key, value) in payload {
      if JSONSerialization.isValidJSONObject(["v": value]) {
        out[key] = value
      } else {
        out[key] = String(describing: value)
      }
    }
    return out
  }

  private var requestContext: (URL, String)? {
    syncOnQueue {
      guard let apiBase = apiBaseURLLocked() else { return nil }
      let token = authHeaderTokenLocked() ?? ""
      return (apiBase, token)
    }
  }

  func fetchReactionDetails(
    chatId: String, messageId: String, completion: @escaping ([String: Any]?) -> Void
  ) {
    queue.async { [weak self] in
      guard let self, let (apiBase, token) = self.requestContext else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      let url = apiBase
        .appendingPathComponent("api")
        .appendingPathComponent("chat")
        .appendingPathComponent(chatId)
        .appendingPathComponent("messages")
        .appendingPathComponent(messageId)
        .appendingPathComponent("reactions")
      var request = URLRequest(url: url)
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
      if !token.isEmpty {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      }
      ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) { data, response, error in
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard error == nil, (200...299).contains(status), let data,
          let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
          DispatchQueue.main.async { completion(nil) }
          return
        }
        DispatchQueue.main.async { completion(body) }
      }.resume()
    }
  }

  private func parseSavedMessagesServerItems(_ data: Data) -> [[String: Any]] {
    let json = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? []
    if let items = json as? [[String: Any]] {
      return items
    }
    if let dict = json as? [String: Any], let items = dict["data"] as? [[String: Any]] {
      return items
    }
    if let dict = json as? [String: Any], let items = dict["messages"] as? [[String: Any]] {
      return items
    }
    return []
  }

  private func parseJSONObjectString(_ raw: Any?) -> [String: Any] {
    guard let text = normalizedString(raw), let data = text.data(using: .utf8) else { return [:] }
    guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else {
      return [:]
    }
    return json as? [String: Any] ?? [:]
  }

  private func normalizeSavedMessagesLocked(_ rawItems: [[String: Any]]) -> [[String: Any]] {
    let privateKey = decryptPrivateKeyLocked()
    let currentUserId = currentUserIdLocked()

    return rawItems.compactMap { raw in
      guard
        let messageId = normalizedString(
          raw["original_message_id"] ?? raw["messageId"] ?? raw["message_id"] ?? raw["id"])
      else { return nil }

      let fromId =
        normalizedString(raw["from_id"] ?? raw["fromId"])
        ?? normalizedString(getConfigValueLocked("userId"))
      let type = normalizedString(raw["type"])?.lowercased() ?? "text"
      let parsedTimestampMs = transcriptTimestampMs(raw)
      if parsedTimestampMs == nil {
        noteSynthesizedTimestamp(chatId: "saved_messages", messageId: messageId, raw: raw)
      }
      let timestampMs = parsedTimestampMs ?? Int64(nowMs())
      let encryptedContent =
        normalizedString(raw["encrypted_content"] ?? raw["encryptedContent"])
      let parsedExtra = parseJSONObjectString(raw["extra"])
      var decryptedFields = parsedExtra

      let plaintextFallback =
        normalizedString(raw["content"] ?? raw["plaintext"] ?? raw["text"]) ?? ""
      if !plaintextFallback.isEmpty {
        decryptedFields["text"] = plaintextFallback
      }

      if let encryptedContent, !encryptedContent.isEmpty {
        let isMe = normalizedUpper(fromId) != nil && normalizedUpper(fromId) == currentUserId
        let parsedEncryptedFields: [String: Any]
        if !isLikelyHybridCiphertext(encryptedContent) {
          parsedEncryptedFields = parseDecryptedMessagePayload(encryptedContent)
        } else if let privateKey {
          let decrypted = chatEngineDecryptHybridMessage(
            privateKey: privateKey,
            ciphertext: encryptedContent,
            isMyMessage: isMe
          )
          parsedEncryptedFields = parseDecryptedMessagePayload(decrypted)
        } else {
          parsedEncryptedFields = [:]
        }
        for (key, value) in parsedEncryptedFields where decryptedFields[key] == nil {
          decryptedFields[key] = value
        }
      }

      let resolvedText = normalizedString(decryptedFields["text"]) ?? plaintextFallback
      let resolvedMediaUrl =
        normalizedString(
          decryptedFields["mediaUrl"] ?? raw["media_url"] ?? raw["mediaUrl"])
      let resolvedFileName =
        normalizedString(
          decryptedFields["fileName"] ?? raw["file_name"] ?? raw["fileName"])
      let resolvedMediaKey = normalizedString(
        decryptedFields["mediaKey"] ?? raw["media_key"] ?? raw["mediaKey"])
      let resolvedLatitude = parseDoubleValue(decryptedFields["latitude"])
      let resolvedLongitude = parseDoubleValue(decryptedFields["longitude"])
      let resolvedDuration = parseDoubleValue(decryptedFields["duration"])
      let resolvedEditedAt = parseLongValue(
        decryptedFields["editedAt"] ?? raw["edited_at"] ?? raw["editedAt"])

      var normalized: [String: Any] = [
        "id": messageId,
        "chatId": "saved_messages",
        "timestamp": timestampMs,
        "timestampMs": timestampMs,
        "type": type,
        "extra": parsedExtra,
      ]
      if let fromId { normalized["fromId"] = fromId }
      if let encryptedContent { normalized["encryptedContent"] = encryptedContent }
      if !resolvedText.isEmpty {
        normalized["plaintext"] = resolvedText
        normalized["text"] = resolvedText
      }
      if let resolvedMediaUrl { normalized["mediaUrl"] = resolvedMediaUrl }
      if let resolvedFileName { normalized["fileName"] = resolvedFileName }
      if let resolvedMediaKey { normalized["mediaKey"] = resolvedMediaKey }
      if let resolvedLatitude { normalized["latitude"] = resolvedLatitude }
      if let resolvedLongitude { normalized["longitude"] = resolvedLongitude }
      if let resolvedDuration { normalized["duration"] = resolvedDuration }
      if let resolvedEditedAt { normalized["editedAt"] = resolvedEditedAt }
      if let status = normalizedString(raw["status"])?.lowercased() {
        normalized["status"] = status
      } else if normalizedUpper(fromId) == currentUserId {
        normalized["status"] = "sent"
      }
      if let isEdited = raw["isEdited"] as? Bool {
        normalized["isEdited"] = isEdited
      }
      if let reactions = raw["reactions"] as? [[String: Any]] {
        normalized["reactions"] = reactions
      }
      if let replyToId = normalizedString(decryptedFields["replyToId"]) {
        normalized["replyToId"] = replyToId
      }
      if let replyPreview = decryptedFields["replyPreview"] ?? decryptedFields["reply_preview"] {
        normalized["replyPreview"] = replyPreview
      }
      if let replyPreviewTitle = normalizedString(
        decryptedFields["replyPreviewTitle"] ?? decryptedFields["reply_preview_title"]
          ?? decryptedFields["replyAuthorName"] ?? decryptedFields["reply_author_name"])
      {
        normalized["replyPreviewTitle"] = replyPreviewTitle
      }
      if let replyPreviewText = normalizedString(
        decryptedFields["replyPreviewText"] ?? decryptedFields["reply_preview_text"]
          ?? decryptedFields["replyText"] ?? decryptedFields["reply_text"])
      {
        normalized["replyPreviewText"] = replyPreviewText
      }
      if let width = decryptedFields["width"] { normalized["width"] = width }
      if let height = decryptedFields["height"] { normalized["height"] = height }
      if let waveform = decryptedFields["waveform"] { normalized["waveform"] = waveform }
      if let isVideoNote = decryptedFields["isVideoNote"] {
        normalized["isVideoNote"] = isVideoNote
      }
      if let contact = decryptedFields["contact"] {
        normalized["contact"] = contact
      }
      if let stickerId = normalizedString(decryptedFields["stickerId"]) {
        normalized["stickerId"] = stickerId
      }
      if let stickerPackId = normalizedString(
        decryptedFields["stickerPackId"] ?? decryptedFields["packId"])
      {
        normalized["stickerPackId"] = stickerPackId
        normalized["packId"] = stickerPackId
      }
      if let stickerBundleFileName = normalizedString(
        decryptedFields["stickerBundleFileName"] ?? decryptedFields["bundleFileName"])
      {
        normalized["stickerBundleFileName"] = stickerBundleFileName
        normalized["bundleFileName"] = stickerBundleFileName
      }
      if let emoji = normalizedString(decryptedFields["emoji"]) {
        normalized["emoji"] = emoji
      }
      var mergedMetadata = (decryptedFields["metadata"] as? [String: Any]) ?? [:]
      if let serverMetadata = raw["metadata"] as? [String: Any] {
        for (key, value) in serverMetadata where mergedMetadata[key] == nil {
          mergedMetadata[key] = value
        }
      }
      for key in ["cover", "artist", "source", "thumbnailBase64", "caption"] {
        if mergedMetadata[key] == nil, let value = decryptedFields[key] {
          mergedMetadata[key] = value
        }
      }
      if !mergedMetadata.isEmpty {
        normalized["metadata"] = mergedMetadata
      }
      return normalized
    }
  }

  func sendSavedMessage(_ payload: [String: Any], completion: @escaping ([String: Any]) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      guard let (apiBase, token) = self.requestContext else {
        DispatchQueue.main.async { completion(["success": false, "reason": "missing_config"]) }
        return
      }
      guard let userId = syncOnQueue({ self.normalizedString(self.getConfigValueLocked("userId")) }) else {
        DispatchQueue.main.async { completion(["success": false, "reason": "missing_user_id"]) }
        return
      }

      let type = self.normalizedString(payload["type"])?.lowercased() ?? "text"
      let text = self.normalizedString(payload["text"]) ?? ""
      let transportMode = syncOnQueue { self.transportModeLocked() }
      let messageId =
        self.normalizedString(payload["messageId"] ?? payload["message_id"] ?? payload["id"])
        ?? UUID().uuidString.lowercased()
      NSLog(
        "[ChatEngine] sendSavedMessage START messageId=%@ type=%@ hasText=%@",
        messageId,
        type,
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "false" : "true")
      let metadata = (payload["metadata"] as? [String: Any]) ?? [:]
      var mediaUrl =
        self.normalizedString(
          metadata["mediaUrl"] ?? metadata["media_url"] ?? payload["mediaUrl"]
            ?? payload["media_url"])
      var fileName =
        self.normalizedString(metadata["fileName"] ?? metadata["file_name"] ?? payload["fileName"])
      var fileSize = self.parseLongValue(
        metadata["fileSize"] ?? metadata["file_size"] ?? payload["fileSize"])
      let latitude = self.parseDoubleValue(metadata["latitude"] ?? payload["latitude"])
      let longitude = self.parseDoubleValue(metadata["longitude"] ?? payload["longitude"])
      let duration = self.parseDoubleValue(metadata["duration"] ?? payload["duration"])
      let thumbnailBase64 = self.normalizedString(
        metadata["thumbnailBase64"] ?? metadata["thumbnail_base64"] ?? payload["thumbnailBase64"])
      let caption = self.normalizedString(metadata["caption"] ?? payload["caption"])
      let waveform = metadata["waveform"] ?? payload["waveform"]
      let musicCover = self.normalizedString(
        metadata["cover"] ?? metadata["coverUrl"] ?? metadata["cover_url"] ?? payload["cover"])
      let musicArtist = self.normalizedString(metadata["artist"] ?? payload["artist"])
      let musicSource = self.normalizedString(
        metadata["source"] ?? metadata["platform"] ?? payload["source"])
      var width = self.parseLongValue(metadata["width"] ?? payload["width"])
      var height = self.parseLongValue(metadata["height"] ?? payload["height"])
      var mediaKey = self.normalizedString(metadata["mediaKey"] ?? metadata["media_key"] ?? payload["mediaKey"])
      let replyToId =
        self.normalizedString(metadata["replyToId"] ?? metadata["reply_to_id"] ?? payload["replyToId"])
      let contact = metadata["contact"] ?? payload["contact"]
      let isVideoNote = metadata["isVideoNote"] ?? payload["isVideoNote"]
      let stickerId = self.normalizedString(metadata["stickerId"] ?? payload["stickerId"])
      let stickerPackId = self.normalizedString(
        metadata["stickerPackId"] ?? metadata["packId"] ?? payload["stickerPackId"]
          ?? payload["packId"])
      let stickerBundleFileName = self.normalizedString(
        metadata["stickerBundleFileName"] ?? metadata["bundleFileName"]
          ?? payload["stickerBundleFileName"] ?? payload["bundleFileName"])
      let stickerEmoji = self.normalizedString(metadata["emoji"] ?? payload["emoji"])
      let myPublicKeyPem = syncOnQueue { self.normalizedString(
        self.getConfigValueLocked("publicKeyPem") ?? self.getConfigValueLocked("publicKey")) }

      if type == "text" && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        DispatchQueue.main.async { completion(["success": false, "reason": "empty_text"]) }
        return
      }
      if transportMode == "bridge_text" && type != "text" {
        DispatchQueue.main.async {
          completion(["success": false, "reason": "media_disabled_in_blackout", "type": type])
        }
        return
      }
      if width == nil || height == nil, ["image", "gif", "video", "file"].contains(type),
        let localForDims = mediaUrl,
        let size = chatMediaFillPixelSize(fromLocalURI: localForDims),
        size.width > 1.0, size.height > 1.0
      {
        width = Int64(size.width)
        height = Int64(size.height)
        chatMediaRecordNaturalSize(size, for: localForDims)
      }
      let uploadableTypes: Set<String> = [
        "image", "gif", "voice", "video", "file", "sticker", "music",
      ]
      if let currentMediaUrl = mediaUrl, uploadableTypes.contains(type),
        self.isLocalMediaURI(currentMediaUrl)
      {
        let uploadOutcome = self.uploadLocalMediaLocked(
          localUri: currentMediaUrl,
          messageType: type,
          fileNameHint: fileName,
          userId: userId,
          token: token,
          apiBase: apiBase
        )
        guard let uploadResult = uploadOutcome.result else {
          DispatchQueue.main.async {
            completion([
              "success": false,
              "reason": uploadOutcome.reason ?? "upload_failed",
              "messageId": messageId,
            ])
          }
          return
        }
        if ["image", "gif", "video"].contains(type) {
          chatMediaSeedRemoteCacheFromLocalFile(
            localURI: currentMediaUrl,
            remoteURL: uploadResult.remoteUrl,
            mediaKey: uploadResult.mediaKey
          )
        }
        mediaUrl = uploadResult.remoteUrl
        if fileName == nil { fileName = uploadResult.fileName }
        if fileSize == nil { fileSize = uploadResult.fileSize }
        mediaKey = uploadResult.mediaKey
      }

      var encryptedContent = ""
      if let myPublicKeyPem, !myPublicKeyPem.isEmpty {
        var encryptedPayload: [String: Any] = ["text": text]
        if let mediaUrl { encryptedPayload["mediaUrl"] = mediaUrl }
        if let mediaKey { encryptedPayload["mediaKey"] = mediaKey }
        if let fileName { encryptedPayload["fileName"] = fileName }
        if let fileSize { encryptedPayload["fileSize"] = fileSize }
        if let latitude { encryptedPayload["latitude"] = latitude }
        if let longitude { encryptedPayload["longitude"] = longitude }
        if let width { encryptedPayload["width"] = width }
        if let height { encryptedPayload["height"] = height }
        if let duration { encryptedPayload["duration"] = duration }
        if let replyToId { encryptedPayload["replyToId"] = replyToId }
        if let contact { encryptedPayload["contact"] = contact }
        if let isVideoNote { encryptedPayload["isVideoNote"] = isVideoNote }
        if let stickerId { encryptedPayload["stickerId"] = stickerId }
        if let stickerPackId { encryptedPayload["stickerPackId"] = stickerPackId }
        if let stickerBundleFileName {
          encryptedPayload["stickerBundleFileName"] = stickerBundleFileName
        }
        if let stickerEmoji { encryptedPayload["emoji"] = stickerEmoji }
        if let thumbnailBase64 { encryptedPayload["thumbnailBase64"] = thumbnailBase64 }
        if let caption { encryptedPayload["caption"] = caption }
        if let waveform { encryptedPayload["waveform"] = waveform }
        if let musicCover { encryptedPayload["cover"] = musicCover }
        if let musicArtist { encryptedPayload["artist"] = musicArtist }
        if let musicSource { encryptedPayload["source"] = musicSource }
        if let payloadString = try? JSONSerialization.data(
          withJSONObject: self.makeJSONSafeMap(encryptedPayload), options: []),
          let messageString = String(data: payloadString, encoding: .utf8),
          let sealed = try? chatEngineEncryptHybridMessage(
            recipientPublicKeyPem: myPublicKeyPem,
            message: messageString,
            myPublicKeyPem: myPublicKeyPem
          )
        {
          encryptedContent = sealed
        }
      }

      var extraPayload: [String: Any] = [:]
      if let fileName { extraPayload["fileName"] = fileName }
      if let fileSize { extraPayload["fileSize"] = fileSize }
      if let latitude { extraPayload["latitude"] = latitude }
      if let longitude { extraPayload["longitude"] = longitude }
      if let width { extraPayload["width"] = width }
      if let height { extraPayload["height"] = height }
      if let duration { extraPayload["duration"] = duration }
      if let replyToId { extraPayload["replyToId"] = replyToId }
      if let isVideoNote { extraPayload["isVideoNote"] = isVideoNote }
      if let stickerId { extraPayload["stickerId"] = stickerId }
      if let stickerPackId {
        extraPayload["stickerPackId"] = stickerPackId
        extraPayload["packId"] = stickerPackId
      }
      if let stickerBundleFileName {
        extraPayload["stickerBundleFileName"] = stickerBundleFileName
        extraPayload["bundleFileName"] = stickerBundleFileName
      }
      if let stickerEmoji { extraPayload["emoji"] = stickerEmoji }

      let requestBody = self.makeJSONSafeMap([
        "user_id": userId,
        "original_message_id": messageId,
        "chat_id": "saved_messages",
        "from_id": userId,
        "encrypted_content": encryptedContent,
        "content": "",
        "type": type,
        "media_url": NSNull(),
        "timestamp": Int64(self.nowMs()),
        "extra": String(
          data: (try? JSONSerialization.data(withJSONObject: extraPayload, options: []))
            ?? Data("{}".utf8),
          encoding: .utf8
        ) ?? "{}",
      ])

      var request = URLRequest(
        url: apiBase.appendingPathComponent("api").appendingPathComponent("saved_messages"))
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
      if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
      request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody, options: [])

      let session = ChatPhoenixClient.makePinnedURLSession()
      session.dataTask(with: request) { data, response, error in
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let success = error == nil && (200...299).contains(statusCode)
        let responseBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let errorText = error?.localizedDescription ?? ""
        NSLog(
          "[ChatEngine] sendSavedMessage %@ messageId=%@ status=%d error=%@ body=%@",
          success ? "OK" : "FAIL",
          messageId,
          statusCode,
          errorText.isEmpty ? "-" : errorText,
          responseBody.isEmpty ? "-" : responseBody
        )
        DispatchQueue.main.async {
          completion([
            "success": success,
            "status": statusCode,
            "messageId": messageId,
            "reason": success ? "ok" : "request_failed",
            "error": errorText,
            "body": responseBody,
          ])
        }
      }.resume()
    }
  }

  // MARK: - Agent Config (Native HTTP)

  func fetchAgentConfig(chatId: String, completion: @escaping ([String: Any]?) -> Void) {
    queue.async { [weak self] in
      guard let self else { return }
      guard chatId != "saved_messages" else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      guard let (apiBase, token) = self.requestContext else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      var request = URLRequest(
        url: apiBase.appendingPathComponent("api").appendingPathComponent("group")
          .appendingPathComponent(chatId).appendingPathComponent("agent"))
      request.httpMethod = "GET"
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
      if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

      let session = ChatPhoenixClient.makePinnedURLSession()
      session.dataTask(with: request) { data, response, error in
        guard let data = data, (response as? HTTPURLResponse)?.statusCode == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
          DispatchQueue.main.async { completion(nil) }
          return
        }
        DispatchQueue.main.async { completion(json) }
      }.resume()
    }
  }

  func saveAgentConfig(chatId: String, config: [String: Any], completion: @escaping (Bool) -> Void)
  {
    queue.async { [weak self] in
      guard let self else { return }
      guard let (apiBase, token) = self.requestContext else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      let endpoint = apiBase.appendingPathComponent("api").appendingPathComponent("group")
        .appendingPathComponent(chatId).appendingPathComponent("agent")
      let safeConfig = self.makeJSONSafeMap(config)
      let payload = (try? JSONSerialization.data(withJSONObject: safeConfig)) ?? Data()

      let hasPersistedId: Bool = {
        if let id = config["id"] as? String {
          return !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return config["id"] != nil
      }()
      let initialMethod = hasPersistedId ? "PUT" : "POST"

      func makeRequest(method: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        if !token.isEmpty {
          request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = payload
        return request
      }

      func send(method: String, completion: @escaping (Int) -> Void) {
        let request = makeRequest(method: method)
        let session = ChatPhoenixClient.makePinnedURLSession()
        session.dataTask(with: request) { _, response, _ in
          completion((response as? HTTPURLResponse)?.statusCode ?? -1)
        }.resume()
      }

      send(method: initialMethod) { statusCode in
        if initialMethod == "POST" && statusCode == 409 {
          send(method: "PUT") { retryStatus in
            let success = (200...299).contains(retryStatus)
            DispatchQueue.main.async { completion(success) }
          }
          return
        }
        let success = (200...299).contains(statusCode)
        DispatchQueue.main.async { completion(success) }
      }
    }
  }

  func generateAgentPrompt(
    chatId: String,
    input: String,
    enabledTools: [String],
    completion: @escaping ([String: Any]?) -> Void
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      guard let (apiBase, token) = self.requestContext else {
        DispatchQueue.main.async { completion(nil) }
        return
      }

      let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedInput.isEmpty else {
        DispatchQueue.main.async { completion(nil) }
        return
      }

      var request = URLRequest(
        url: apiBase.appendingPathComponent("api").appendingPathComponent("group")
          .appendingPathComponent(chatId).appendingPathComponent("agent")
          .appendingPathComponent("generate_prompt"))
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
      if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

      let safeTools =
        enabledTools
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      let body: [String: Any] = [
        "input": trimmedInput,
        "enabled_tools": safeTools,
      ]
      request.httpBody = try? JSONSerialization.data(withJSONObject: body)

      let session = ChatPhoenixClient.makePinnedURLSession()
      session.dataTask(with: request) { data, response, _ in
        guard
          let data = data,
          (response as? HTTPURLResponse)?.statusCode == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
          DispatchQueue.main.async { completion(nil) }
          return
        }
        DispatchQueue.main.async { completion(json) }
      }.resume()
    }
  }

  func deleteAgentConfig(chatId: String, completion: @escaping (Bool) -> Void) {
    queue.async { [weak self] in
      guard let self else { return }
      guard let (apiBase, token) = self.requestContext else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      var request = URLRequest(
        url: apiBase.appendingPathComponent("api").appendingPathComponent("group")
          .appendingPathComponent(chatId).appendingPathComponent("agent"))
      request.httpMethod = "DELETE"
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
      if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

      let session = ChatPhoenixClient.makePinnedURLSession()
      session.dataTask(with: request) { data, response, error in
        let success = (200...299).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
        DispatchQueue.main.async { completion(success) }
      }.resume()
    }
  }
}
