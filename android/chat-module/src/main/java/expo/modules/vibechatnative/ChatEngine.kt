package expo.modules.vibechatnative

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.Base64
import android.util.Log
import expo.modules.vibechatnative.notifications.VibeNativeCallStore
import expo.modules.vibechatnative.notifications.VibePushTokenSync
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.buffer
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.InterruptedIOException
import java.net.SocketTimeoutException
import java.nio.charset.StandardCharsets
import java.security.KeyFactory
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.spec.MGF1ParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import javax.crypto.spec.SecretKeySpec

private val chatEngineOaepSpec = OAEPParameterSpec(
  "SHA-256",
  "MGF1",
  MGF1ParameterSpec.SHA256,
  PSource.PSpecified.DEFAULT,
)
private const val minimumNativeUploadProgress = 0.027f
private const val uploadProgressFrameIntervalMs = 33L
private const val uploadProgressStep = 0.01f
private const val chatHistoryFetchLimit = 100

private fun chatEngineDecodePem(pem: String): ByteArray {
  val sanitized = pem
    .replace(Regex("-----BEGIN [A-Z ]+-----"), "")
    .replace(Regex("-----END [A-Z ]+-----"), "")
    .replace(Regex("\\\\n"), "\n")
    .replace(Regex("\\\\r"), "")
    .replace(Regex("\\s+"), "")
  return Base64.decode(sanitized, Base64.DEFAULT)
}

private fun chatEngineLoadPrivateKeyFromPem(privateKeyPem: String): PrivateKey {
  val keyFactory = KeyFactory.getInstance("RSA")
  val der = chatEngineDecodePem(privateKeyPem)

  // Try PKCS#8 first ("BEGIN PRIVATE KEY")
  try {
    return keyFactory.generatePrivate(PKCS8EncodedKeySpec(der))
  } catch (_: Throwable) { /* fall through */ }

  // Wrap PKCS#1 ("BEGIN RSA PRIVATE KEY") DER inside a PKCS#8 envelope.
  // PKCS#8 = SEQUENCE { version(0), AlgorithmIdentifier(rsaEncryption, NULL), OCTET STRING(pkcs1) }
  val rsaOidHeader = byteArrayOf(
    0x30, 0x0d,                             // SEQUENCE (13 bytes) — AlgorithmIdentifier
    0x06, 0x09, 0x2a, 0x86.toByte(), 0x48, 0x86.toByte(),
    0xf7.toByte(), 0x0d, 0x01, 0x01, 0x01, // OID 1.2.840.113549.1.1.1 (rsaEncryption)
    0x05, 0x00                              // NULL
  )
  val versionBytes = byteArrayOf(0x02, 0x01, 0x00) // INTEGER 0
  val octetTag = byteArrayOf(0x04)
  val octetLen = derEncodeLength(der.size)
  val innerLen = versionBytes.size + rsaOidHeader.size + octetTag.size + octetLen.size + der.size
  val seqTag = byteArrayOf(0x30)
  val seqLen = derEncodeLength(innerLen)
  val pkcs8 = seqTag + seqLen + versionBytes + rsaOidHeader + octetTag + octetLen + der
  try {
    return keyFactory.generatePrivate(PKCS8EncodedKeySpec(pkcs8))
  } catch (e: Throwable) {
    Log.e("ChatEngine", "chatEngineLoadPrivateKeyFromPem FAILED derLen=${der.size}", e)
    throw e
  }
}

/** Encode an ASN.1 DER length field. */
private fun derEncodeLength(length: Int): ByteArray {
  if (length < 0x80) return byteArrayOf(length.toByte())
  val lenBytes = mutableListOf<Byte>()
  var remaining = length
  while (remaining > 0) {
    lenBytes.add(0, (remaining and 0xFF).toByte())
    remaining = remaining shr 8
  }
  return byteArrayOf((0x80 or lenBytes.size).toByte()) + lenBytes.toByteArray()
}

private fun chatEngineLoadPublicKeyFromPem(publicKeyPem: String): PublicKey {
  val keyFactory = KeyFactory.getInstance("RSA")
  return keyFactory.generatePublic(X509EncodedKeySpec(chatEngineDecodePem(publicKeyPem)))
}

private fun chatEngineRsaDecryptOAEP(privateKey: PrivateKey, encrypted: ByteArray): ByteArray? {
  return try {
    val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
    cipher.init(Cipher.DECRYPT_MODE, privateKey, chatEngineOaepSpec)
    cipher.doFinal(encrypted)
  } catch (_: Throwable) {
    null
  }
}

private fun chatEngineRsaEncryptOAEP(publicKey: PublicKey, plain: ByteArray): ByteArray {
  val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
  cipher.init(Cipher.ENCRYPT_MODE, publicKey, chatEngineOaepSpec)
  return cipher.doFinal(plain)
}

private fun chatEngineDecryptHybridMessage(
  privateKey: PrivateKey,
  ciphertext: String,
  isMyMessage: Boolean,
): String {
  val trimmed = ciphertext.trim()
  if (trimmed.isEmpty()) return ""
  if (!trimmed.startsWith("{")) return ""
  return try {
    val payload = JSONObject(trimmed)
    val ivB64 = payload.optString("iv", "")
    val cB64 = payload.optString("c", "")
    val kB64 = payload.optString("k", "")
    if (ivB64.isEmpty() || cB64.isEmpty() || kB64.isEmpty()) return ""

    val keyCandidates = ArrayList<String>(2)
    val senderKey = payload.optString("s", "")
    if (isMyMessage) {
      if (senderKey.isNotEmpty()) keyCandidates.add(senderKey)
      keyCandidates.add(kB64)
    } else {
      keyCandidates.add(kB64)
      if (senderKey.isNotEmpty()) keyCandidates.add(senderKey)
    }

    var aesKey: ByteArray? = null
    for (candidate in keyCandidates) {
      val encryptedKey = Base64.decode(candidate, Base64.DEFAULT)
      val decrypted = chatEngineRsaDecryptOAEP(privateKey, encryptedKey)
      if (decrypted != null) {
        aesKey = decrypted
        break
      }
    }
    val resolvedAesKey = aesKey ?: return ""
    val iv = Base64.decode(ivB64, Base64.DEFAULT)
    val encryptedWithTag = Base64.decode(cB64, Base64.DEFAULT)
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(
      Cipher.DECRYPT_MODE,
      SecretKeySpec(resolvedAesKey, "AES"),
      GCMParameterSpec(128, iv),
    )
    val plaintextBytes = cipher.doFinal(encryptedWithTag)
    String(plaintextBytes, StandardCharsets.UTF_8)
  } catch (_: Throwable) {
    ""
  }
}

private fun chatEngineEncryptHybridMessage(
  recipientPublicKeyPem: String,
  message: String,
  myPublicKeyPem: String?,
): String {
  val secureRandom = SecureRandom()
  val aesKey = ByteArray(32).also { secureRandom.nextBytes(it) }
  val iv = ByteArray(12).also { secureRandom.nextBytes(it) }

  val aesCipher = Cipher.getInstance("AES/GCM/NoPadding")
  aesCipher.init(
    Cipher.ENCRYPT_MODE,
    SecretKeySpec(aesKey, "AES"),
    GCMParameterSpec(128, iv),
  )
  val encryptedWithTag = aesCipher.doFinal(message.toByteArray(StandardCharsets.UTF_8))

  val recipientPublicKey = chatEngineLoadPublicKeyFromPem(recipientPublicKeyPem)
  val encryptedRecipientKey = chatEngineRsaEncryptOAEP(recipientPublicKey, aesKey)

  var senderEncryptedKeyB64: String? = null
  if (!myPublicKeyPem.isNullOrBlank()) {
    try {
      val senderPublicKey = chatEngineLoadPublicKeyFromPem(myPublicKeyPem)
      senderEncryptedKeyB64 = Base64.encodeToString(
        chatEngineRsaEncryptOAEP(senderPublicKey, aesKey),
        Base64.NO_WRAP,
      )
    } catch (_: Throwable) {
      // Keep payload valid if sender-key branch fails.
    }
  }

  return JSONObject().apply {
    put("v", 1)
    put("iv", Base64.encodeToString(iv, Base64.NO_WRAP))
    put("c", Base64.encodeToString(encryptedWithTag, Base64.NO_WRAP))
    put("k", Base64.encodeToString(encryptedRecipientKey, Base64.NO_WRAP))
    if (senderEncryptedKeyB64 != null) put("s", senderEncryptedKeyB64)
  }.toString()
}

internal fun chatEngineEncryptMediaBytes(plainData: ByteArray): Pair<ByteArray, String> {
  val secureRandom = SecureRandom()
  val aesKey = ByteArray(32).also { secureRandom.nextBytes(it) }
  val iv = ByteArray(12).also { secureRandom.nextBytes(it) }

  val cipher = Cipher.getInstance("AES/GCM/NoPadding")
  cipher.init(
    Cipher.ENCRYPT_MODE,
    SecretKeySpec(aesKey, "AES"),
    GCMParameterSpec(128, iv),
  )
  val encryptedWithTag = cipher.doFinal(plainData)
  val combined = ByteArray(iv.size + encryptedWithTag.size)
  System.arraycopy(iv, 0, combined, 0, iv.size)
  System.arraycopy(encryptedWithTag, 0, combined, iv.size, encryptedWithTag.size)
  return combined to Base64.encodeToString(aesKey, Base64.NO_WRAP)
}

internal fun chatEngineDecryptMediaBytes(
  encryptedData: ByteArray,
  keyBase64: String,
): ByteArray? {
  return try {
    val aesKey = Base64.decode(keyBase64, Base64.DEFAULT)
    if (encryptedData.size <= 28) return null
    val iv = encryptedData.copyOfRange(0, 12)
    val cipherBytes = encryptedData.copyOfRange(12, encryptedData.size)
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(
      Cipher.DECRYPT_MODE,
      SecretKeySpec(aesKey, "AES"),
      GCMParameterSpec(128, iv),
    )
    cipher.doFinal(cipherBytes)
  } catch (_: Throwable) {
    null
  }
}

internal fun chatEngineShouldEncryptUploadedMediaType(messageType: String): Boolean =
  when (messageType.lowercase(Locale.ROOT)) {
    "image", "gif", "voice", "music", "video", "file", "sticker" -> true
    else -> false
  }

internal object ChatEngine {
  private const val NATIVE_CONNECT_STALE_TIMEOUT_MS = 5_000L

  private data class SurfaceBinding(
    val surfaceId: String,
    val chatId: String?,
    val myUserId: String?,
    val peerUserId: String?,
  )

  @Volatile private var appContextRef: Context? = null
  private val lock = Any()
  private val state = ConcurrentHashMap<String, Any?>(
    mapOf(
      "state" to "idle",
      "connected" to false,
      "updatedAt" to 0L,
      "note" to "ChatEngine scaffold (shadow mode)",
    ),
  )
  private val onlineUsers = linkedSetOf<String>()
  private val lastSeenByUserId = linkedMapOf<String, Long>()
  private val surfaceBindings = linkedMapOf<String, SurfaceBinding>()
  private val openChatChannels = linkedMapOf<String, Int>()
  private val receiptIndex = linkedMapOf<String, MutableMap<String, String>>() // chatId -> messageId -> status
  private val localStatusIndex = linkedMapOf<String, MutableMap<String, String>>() // chatId -> messageId -> status
  private val listeners = linkedMapOf<String, (String, String?, String?) -> Unit>()
  private var phoenixClient: ChatRealtimeTransport? = null
  private var nativePresenceActive = false
  private var nativeUserTopic: String? = null
  private var nativeUserJoinRef: String? = null
  private var nativeSocketSignature: String? = null
  private val nativeChatJoinRefsByRef = linkedMapOf<String, String>()
  private val nativeJoinedChatIds = linkedSetOf<String>()
  private val nativePendingMessagePushRefs = linkedMapOf<String, Pair<String, String>>() // ref -> (chatId,messageId)
  private val nativePendingEditPushRefs = linkedMapOf<String, Pair<String, String>>() // ref -> (chatId,messageId)
  private val nativePendingDeletePushRefs = linkedMapOf<String, Pair<String, String>>() // ref -> (chatId,messageId)
  private val pendingOutboundDraftsByMessageId = linkedMapOf<String, Map<String, Any?>>()
  private val pendingOutboundQueueByChat = linkedMapOf<String, MutableList<String>>()
  private val activeMediaUploadCallsByMessageId = linkedMapOf<String, Call>()
  private val canceledOutboundMessageIds = linkedSetOf<String>()
  private val nativeTypingStateByChatId = linkedMapOf<String, Boolean>()
  private val peerTypingUserIdsByChatId = linkedMapOf<String, MutableSet<String>>()
  private val nativeRecordingStateByChatId = linkedMapOf<String, Boolean>()
  private val pinnedMessagesByChatId = linkedMapOf<String, MutableList<Map<String, Any?>>>()
  private val pinnedFetchInFlightChatIds = linkedSetOf<String>()
  private val historyRowsByChat = linkedMapOf<String, MutableList<Map<String, Any?>>>()
  private val historyLoadingChats = linkedSetOf<String>()
  private val liveMessageRowsByChat = linkedMapOf<String, MutableMap<String, Map<String, Any?>>>()
  private val deletedMessageIdsByChat = linkedMapOf<String, MutableSet<String>>()
  private val chatPeerUserIdsByChatId = linkedMapOf<String, String>()
  private val friendPublicKeysByUserId = linkedMapOf<String, String>()
  private var configuredUserId: String? = null
  private var cachedDecryptPrivateKeyPem: String? = null
  private var cachedDecryptPrivateKey: PrivateKey? = null
  private var cachedDecryptKeyTimestampMs: Long = 0L
  /// Time-to-live for the cached private key in memory (milliseconds).
  /// After this period of inactivity the key is cleared and re-derived from secure storage.
  private val keyTTLMs: Long = 300_000L
  // Use the same pinned OkHttpClient with cert pinning + TLS enforcement
  // for history HTTP requests as the WebSocket connection uses.
  private val historyHttpClient by lazy { ChatPhoenixClient.buildPinnedHttpClient() }
  private val mediaUploadHttpClient by lazy {
    ChatPhoenixClient.buildPinnedHttpClient()
      .newBuilder()
      .connectTimeout(20L, TimeUnit.SECONDS)
      .writeTimeout(40L, TimeUnit.SECONDS)
      .readTimeout(40L, TimeUnit.SECONDS)
      .callTimeout(45L, TimeUnit.SECONDS)
      .build()
  }
  private const val fallbackApiBaseURL = "https://api.vibegram.io"
  private const val AGENT_USER_ID = "00000000-0000-0000-0000-000000000001"

  private fun currentOutboundUserIdLocked(): String? =
    appContextRef?.let(ChatEngineStore::getConfig)?.let { normalized(it["userId"]) }

  private fun persistOutboundStateLocked() {
    val ctx = appContextRef ?: return
    val userId = currentOutboundUserIdLocked() ?: return
    if (pendingOutboundDraftsByMessageId.isEmpty() && pendingOutboundQueueByChat.isEmpty()) {
      ChatEngineStore.clearOutboundState(ctx)
      return
    }
    ChatEngineStore.setOutboundState(
      ctx,
      mapOf(
        "userId" to userId,
        "updatedAt" to System.currentTimeMillis(),
        "draftsByMessageId" to pendingOutboundDraftsByMessageId,
        "queueByChat" to pendingOutboundQueueByChat,
      ),
    )
  }

  private fun restoreOutboundStateLocked() {
    if (pendingOutboundDraftsByMessageId.isNotEmpty() || pendingOutboundQueueByChat.isNotEmpty()) return
    val ctx = appContextRef ?: return
    val payload = ChatEngineStore.getOutboundState(ctx)
    if (payload.isEmpty()) return
    val storedUserId = normalized(payload["userId"]) ?: return
    val currentUserId = currentOutboundUserIdLocked()
    if (currentUserId == null || currentUserId != storedUserId) {
      ChatEngineStore.clearOutboundState(ctx)
      return
    }

    val rawDrafts = payload["draftsByMessageId"] as? Map<*, *> ?: emptyMap<Any?, Any?>()
    rawDrafts.forEach { (messageIdRaw, value) ->
      val messageId = normalized(messageIdRaw) ?: return@forEach
      val draft = value as? Map<String, Any?> ?: return@forEach
      pendingOutboundDraftsByMessageId[messageId] = LinkedHashMap(draft)
    }

    val rawQueues = payload["queueByChat"] as? Map<*, *> ?: emptyMap<Any?, Any?>()
    rawQueues.forEach { (chatIdRaw, value) ->
      val chatId = normalized(chatIdRaw) ?: return@forEach
      val ids = (value as? List<*>)?.mapNotNull { normalized(it) }.orEmpty()
      if (ids.isNotEmpty()) {
        pendingOutboundQueueByChat[chatId] = ids.toMutableList()
      }
    }

    if (pendingOutboundDraftsByMessageId.isNotEmpty() || pendingOutboundQueueByChat.isNotEmpty()) {
      appendJournalLocked(
        "native-outgoing-restored",
        mapOf("drafts" to pendingOutboundDraftsByMessageId.size, "chats" to pendingOutboundQueueByChat.size),
      )
    }
  }

  private fun hasNativeSocketConfigLocked(): Boolean {
    val ctx = appContextRef ?: return false
    val config = ChatEngineStore.getConfig(ctx)
    val transportMode = transportModeLocked(config)
    val socketUrl = normalized(config["socketUrl"] ?: config["url"])
    val userId = normalized(config["userId"])
    val token = normalized(config["authToken"] ?: config["token"])
    if (transportMode == "offline") {
      return userId != null && token != null
    }
    if (transportMode == "bridge_text") {
      return bridgeBaseUrlLocked(config) != null && userId != null && token != null
    }
    return socketUrl != null && userId != null && token != null
  }

  private fun deriveSocketUrlFromApiBase(apiBaseUrl: String): String? {
    val trimmed = apiBaseUrl.trim().trimEnd('/')
    if (trimmed.isBlank()) return null
    return trimmed.replaceFirst(Regex("^http", RegexOption.IGNORE_CASE), "ws") + "/socket"
  }

  @Suppress("LongMethod")
  private fun bootstrapConfigFromNativeSessionIfNeededLocked(trigger: String): Boolean {
    if (hasNativeSocketConfigLocked()) return true
    val ctx = appContextRef ?: run {
      appendJournalLocked(
        "native-config-bootstrap-skip",
        mapOf("trigger" to trigger, "reason" to "missing_context"),
      )
      return false
    }

    val existing = ChatEngineStore.getConfig(ctx)
    val nativeCallConfig = try {
      VibeNativeCallStore.getNativeEngineConfig(ctx)
    } catch (_: Throwable) {
      emptyMap()
    }

    val userId = normalized(existing["userId"] ?: nativeCallConfig["userId"])
      ?: run {
        appendJournalLocked(
          "native-config-bootstrap-skip",
          mapOf("trigger" to trigger, "reason" to "missing_user_id"),
        )
        return false
      }

    val apiBase =
      normalized(
        existing["apiBaseUrl"] ?: existing["baseUrl"] ?: nativeCallConfig["baseUrl"]
          ?: nativeCallConfig["apiBaseUrl"],
      )
        ?: fallbackApiBaseURL
    val socketUrl =
      normalized(
        existing["socketUrl"] ?: existing["url"] ?: nativeCallConfig["socketUrl"]
          ?: nativeCallConfig["signalingUrl"],
      )
        ?: deriveSocketUrlFromApiBase(apiBase)
        ?: run {
          appendJournalLocked(
            "native-config-bootstrap-skip",
            mapOf("trigger" to trigger, "reason" to "missing_socket_url"),
          )
          return false
        }
    val token =
      normalized(
        existing["authToken"] ?: existing["token"] ?: nativeCallConfig["authToken"]
          ?: nativeCallConfig["token"],
      ) ?: userId

    val merged = LinkedHashMap(existing)
    merged["apiBaseUrl"] = apiBase
    merged["socketUrl"] = socketUrl
    merged["authToken"] = token
    merged["userId"] = userId
    if (normalized(existing["userChannelTopic"]) == null) {
      merged["userChannelTopic"] = "user:$userId"
    }
    if (normalized(existing["privateKeyPem"] ?: existing["privateKey"]) == null) {
      val privateKeyPem = normalized(nativeCallConfig["privateKeyPem"] ?: nativeCallConfig["privateKey"])
      if (!privateKeyPem.isNullOrBlank()) {
        merged["privateKeyPem"] = privateKeyPem
      }
    }
    if (normalized(existing["publicKeyPem"] ?: existing["publicKey"]) == null) {
      val publicKeyPem = normalized(nativeCallConfig["publicKeyPem"] ?: nativeCallConfig["publicKey"])
      if (!publicKeyPem.isNullOrBlank()) {
        merged["publicKeyPem"] = publicKeyPem
      }
    }

    ChatEngineStore.setConfig(ctx, merged)
    state["state"] = "configured-native-bootstrap"
    state["updatedAt"] = System.currentTimeMillis()
    state["configuredAt"] = state["updatedAt"]
    state["configKeys"] = merged.keys.sorted()
    state["note"] = "ChatEngine configured from native session"
    state["presenceSource"] = if (nativePresenceActive) "native" else "shadow"
    appendJournalLocked(
      "native-config-bootstrap",
      mapOf(
        "trigger" to trigger,
        "hasSocketUrl" to (normalized(merged["socketUrl"] ?: merged["url"]) != null),
        "hasUserId" to (normalized(merged["userId"]) != null),
        "hasToken" to (normalized(merged["authToken"] ?: merged["token"]) != null),
        "hasPrivateKey" to (normalized(merged["privateKeyPem"] ?: merged["privateKey"]) != null),
        "hasPublicKey" to (normalized(merged["publicKeyPem"] ?: merged["publicKey"]) != null),
      ),
    )
    return true
  }

  private fun ensureNativeTransport(trigger: String) {
    var clientToDisconnect: ChatRealtimeTransport? = null
    var shouldEmitStateChange = false
    val shouldConnect = synchronized(lock) {
      val connected = state["connected"] == true
      var currentState = normalized(state["state"])?.lowercase().orEmpty()
      val nowMs = System.currentTimeMillis()
      val updatedAtMs = (state["updatedAt"] as? Number)?.toLong() ?: 0L
      val stateAgeMs = if (updatedAtMs > 0L) nowMs - updatedAtMs else -1L
      if (currentState == "connecting-native-presence" && stateAgeMs >= NATIVE_CONNECT_STALE_TIMEOUT_MS) {
        Log.w(
          "ChatEngine",
          "ensureNativeTransport resetting stale connect trigger=$trigger stateAgeMs=$stateAgeMs hasClient=${phoenixClient != null}",
        )
        appendJournalLocked(
          "native-connect-stale",
          mapOf("trigger" to trigger, "stateAgeMs" to stateAgeMs, "hasClient" to (phoenixClient != null)),
        )
        clientToDisconnect = phoenixClient
        phoenixClient = null
        nativeSocketSignature = null
        nativePresenceActive = false
        nativeUserJoinRef = null
        nativeUserTopic = null
        nativeChatJoinRefsByRef.clear()
        nativeJoinedChatIds.clear()
        nativePendingMessagePushRefs.clear()
        nativePendingEditPushRefs.clear()
        nativePendingDeletePushRefs.clear()
        nativeTypingStateByChatId.clear()
        peerTypingUserIdsByChatId.clear()
        nativeRecordingStateByChatId.clear()
        pinnedFetchInFlightChatIds.clear()
        historyLoadingChats.clear()
        state["connected"] = false
        state["state"] = "native-connect-stale"
        state["updatedAt"] = nowMs
        state["presenceSource"] = "shadow"
        currentState = "native-connect-stale"
        shouldEmitStateChange = true
      }
      if (connected || currentState == "connecting-native-presence" || currentState == "native-socket-open") {
        false
      } else if (transportModeLocked() == "offline") {
        false
      } else {
        bootstrapConfigFromNativeSessionIfNeededLocked(trigger)
      }
    }
    clientToDisconnect?.disconnect()
    if (shouldEmitStateChange) {
      emitChangeLocked("connectionStateChanged", null, null)
    }
    if (shouldConnect) {
      connect()
    }
  }

  private fun ensureNativeTransportAsync(trigger: String) {
    Thread {
      try {
        ensureNativeTransport(trigger)
      } catch (t: Throwable) {
        Log.e("ChatEngine", "ensureNativeTransportAsync failed trigger=$trigger", t)
      }
    }.apply { isDaemon = true }.start()
  }

  fun configure(context: Context, payload: Map<String, Any?>): Map<String, Any?> {
    appContextRef = context.applicationContext
    ChatEngineStore.setConfig(context, payload)
    val snapshot = synchronized(lock) {
      val nextUserId = normalized(payload["userId"])
      if (configuredUserId != null && configuredUserId != nextUserId) {
        pendingOutboundDraftsByMessageId.clear()
        pendingOutboundQueueByChat.clear()
        ChatEngineStore.clearOutboundState(context)
      }
      configuredUserId = nextUserId
      restoreOutboundStateLocked()
      state["state"] = "configured"
      state["updatedAt"] = System.currentTimeMillis()
      state["configuredAt"] = state["updatedAt"]
      state["configKeys"] = payload.keys.sorted()
      state["note"] = "ChatEngine configured (native Phoenix presence enabled, shadow fallback active)"
      state["presenceSource"] = if (nativePresenceActive) "native" else "shadow"
      appendJournalLocked("configure", mapOf("keys" to payload.keys.sorted()))
      openChatChannels.keys.forEach { joinNativeChatTopicIfNeededLocked(it) }
      val result = statusSnapshotLocked()
      emitChangeLocked("configure", null, null)
      result
    }
    ensureNativeTransport("configure")
    VibePushTokenSync.syncStoredPushTokens(context, payload, "chat-engine-configure")
    return snapshot
  }

  fun getStatus(): Map<String, Any?> =
    synchronized(lock) { statusSnapshotLocked() }

  fun getTransportStatus(): Map<String, Any?> =
    synchronized(lock) { statusSnapshotLocked() }

  fun authorizationHeaderForApi(): String? =
    synchronized(lock) {
      authHeaderTokenLocked()?.takeIf { it.isNotBlank() }?.let { "Bearer $it" }
    }

  private fun transportDebugStateLocked(chatId: String? = null): String {
    val connected = (state["connected"] as? Boolean) == true
    val socketState = normalized(state["state"]) ?: "-"
    val hasClient = phoenixClient != null
    val openChatCount = if (chatId != null) (openChatChannels[chatId] ?: 0) else openChatChannels.size
    val joined = if (chatId != null) nativeJoinedChatIds.contains(chatId) else nativeJoinedChatIds.isNotEmpty()
    val joining = if (chatId != null) nativeChatJoinRefsByRef.values.contains(chatId) else nativeChatJoinRefsByRef.isNotEmpty()
    val queued = if (chatId != null) (pendingOutboundQueueByChat[chatId]?.size ?: 0) else pendingOutboundQueueByChat.values.sumOf { it.size }
    val inFlight = if (chatId != null) {
      nativePendingMessagePushRefs.values.count { it.first == chatId }
    } else {
      nativePendingMessagePushRefs.size
    }
    return "connected=$connected socketState=$socketState hasClient=$hasClient openChats=$openChatCount joined=$joined joining=$joining queued=$queued inFlight=$inFlight"
  }

  private fun transportModeLocked(config: Map<String, Any?>? = null): String {
    val resolved = config ?: appContextRef?.let(ChatEngineStore::getConfig).orEmpty()
    return when (normalized(resolved["transportMode"])?.lowercase()) {
      "packet_mesh", "bridge_text", "offline" -> normalized(resolved["transportMode"])!!.lowercase()
      else -> "direct"
    }
  }

  private fun isBridgeTextModeLocked(config: Map<String, Any?>? = null): Boolean =
    transportModeLocked(config) == "bridge_text"

  private fun disableMediaLocked(config: Map<String, Any?>? = null): Boolean {
    val resolved = config ?: appContextRef?.let(ChatEngineStore::getConfig).orEmpty()
    return parseBooleanValue(resolved["disableMedia"]) ?: isBridgeTextModeLocked(resolved)
  }

  private fun disableCallsLocked(config: Map<String, Any?>? = null): Boolean {
    val resolved = config ?: appContextRef?.let(ChatEngineStore::getConfig).orEmpty()
    return parseBooleanValue(resolved["disableCalls"]) ?: isBridgeTextModeLocked(resolved)
  }

  private fun disableRemoteAvatarsLocked(config: Map<String, Any?>? = null): Boolean {
    val resolved = config ?: appContextRef?.let(ChatEngineStore::getConfig).orEmpty()
    return parseBooleanValue(resolved["disableRemoteAvatars"]) ?: isBridgeTextModeLocked(resolved)
  }

  private fun bridgeBaseUrlLocked(config: Map<String, Any?>? = null): String? {
    val resolved = config ?: appContextRef?.let(ChatEngineStore::getConfig).orEmpty()
    normalized(resolved["bridgeBaseUrl"])?.let { return it.trimEnd('/') }
    val activeBridgeId = normalized(resolved["activeBridgeId"])
    val bundle = resolved["bridgeBundle"] as? Map<*, *> ?: return null
    val descriptors = bundle["descriptors"] as? List<*> ?: return null
    val preferred = descriptors.mapNotNull { it as? Map<*, *> }.firstOrNull {
      normalized(it["id"]) == activeBridgeId
    } ?: descriptors.mapNotNull { it as? Map<*, *> }.sortedBy {
      (it["priority"] as? Number)?.toInt() ?: 999
    }.firstOrNull()
    preferred ?: return null
    normalized(preferred["baseUrl"])?.let { return it.trimEnd('/') }
    val host = normalized(preferred["host"]) ?: return null
    val scheme = if (normalized(preferred["transport"]) == "http") "http" else "https"
    val port = (preferred["port"] as? Number)?.toInt()?.let { ":$it" }.orEmpty()
    val pathPrefix = normalized(preferred["pathPrefix"])?.trim('/')?.takeIf { it.isNotEmpty() }
    return buildString {
      append("$scheme://$host$port")
      if (!pathPrefix.isNullOrBlank()) {
        append("/")
        append(pathPrefix)
      }
    }
  }

  private fun packetProxyPortLocked(config: Map<String, Any?>? = null): Int? {
    val resolved = config ?: appContextRef?.let(ChatEngineStore::getConfig).orEmpty()
    return when (val value = resolved["packetProxyPort"]) {
      is Number -> value.toInt()
      is String -> value.trim().toIntOrNull()
      else -> null
    }
  }

  private fun packetProxyHostLocked(config: Map<String, Any?>? = null): String {
    val resolved = config ?: appContextRef?.let(ChatEngineStore::getConfig).orEmpty()
    return normalized(resolved["packetProxyHost"]) ?: "127.0.0.1"
  }

  private fun bridgeUrlLocked(path: String, config: Map<String, Any?>? = null): String? {
    val base = bridgeBaseUrlLocked(config) ?: return null
    return base.trimEnd('/') + "/" + path.trimStart('/')
  }

  fun isUserOnline(userId: String?): Boolean =
    synchronized(lock) {
      val normalized = normalizedUpper(userId) ?: return@synchronized false
      onlineUsers.contains(normalized)
    }

  fun lastSeenTimestampMs(userId: String?): Long? =
    synchronized(lock) {
      val normalized = normalizedUpper(userId) ?: return@synchronized null
      lastSeenByUserId[normalized]
    }

  fun connect(): Map<String, Any?> {
    val ctx = appContextRef
    if (ctx == null) {
      synchronized(lock) {
        state["state"] = "native-config-missing"
        state["connected"] = false
        state["updatedAt"] = System.currentTimeMillis()
        state["note"] = "ChatEngine missing app context for native connect"
        appendJournalLocked("connect-native-missing-context", emptyMap())
        val result = statusSnapshotLocked()
        emitChangeLocked("connectionStateChanged", null, null)
        return result
      }
    }
    synchronized(lock) {
      bootstrapConfigFromNativeSessionIfNeededLocked("connect_native_presence")
    }
    val config = ChatEngineStore.getConfig(ctx)
    val transportMode = transportModeLocked(config)
    val socketUrl = normalized(config["socketUrl"] ?: config["url"])
    val bridgeBaseUrl = bridgeBaseUrlLocked(config)
    val packetProxyPort = packetProxyPortLocked(config)
    val packetProxyHost = packetProxyHostLocked(config)
    val authToken = normalized(config["authToken"] ?: config["token"])
    val userId = normalized(config["userId"])
    val userTopic = normalized(config["userChannelTopic"]) ?: userId?.let { "user:$it" }
    if (transportMode == "offline") {
      synchronized(lock) {
        state["state"] = "offline"
        state["connected"] = false
        state["updatedAt"] = System.currentTimeMillis()
        state["transportMode"] = transportMode
        state["note"] = "ChatEngine realtime transport disabled"
        appendJournalLocked(
          "connect-native-offline",
          mapOf(
            "hasUserTopic" to (userTopic != null),
          ),
        )
        val result = statusSnapshotLocked()
        emitChangeLocked("connectionStateChanged", null, null)
        return result
      }
    }

    val resolvedTarget = if (transportMode == "bridge_text") bridgeBaseUrl else socketUrl
    val hasRequiredPacketProxy = transportMode != "packet_mesh" || packetProxyPort != null
    if (resolvedTarget == null || userTopic == null || !hasRequiredPacketProxy) {
      synchronized(lock) {
        state["state"] = "native-config-missing"
        state["connected"] = false
        state["updatedAt"] = System.currentTimeMillis()
        state["transportMode"] = transportMode
        state["note"] =
          if (transportMode == "bridge_text") {
            "ChatEngine blackout bridge missing bridgeBaseUrl/userTopic config"
          } else if (transportMode == "packet_mesh") {
            "ChatEngine packet mesh missing socketUrl/userTopic/packetProxyPort config"
          } else {
            "ChatEngine native presence missing socketUrl/userTopic config"
          }
        appendJournalLocked(
          "connect-native-missing-config",
          mapOf(
            "hasSocketUrl" to (socketUrl != null),
            "hasBridgeBaseUrl" to (bridgeBaseUrl != null),
            "hasPacketProxyPort" to (packetProxyPort != null),
            "hasUserTopic" to (userTopic != null),
            "hasAuthToken" to (authToken != null),
            "transportMode" to transportMode,
          ),
        )
        val result = statusSnapshotLocked()
        emitChangeLocked("connectionStateChanged", null, null)
        return result
      }
    }

    val signature = "$transportMode|$resolvedTarget|${authToken ?: ""}|$userTopic"
    var clientToDisconnect: ChatRealtimeTransport? = null
    var clientToConnect: ChatRealtimeTransport? = null
    var openChatIdsSnapshot: List<String> = emptyList()
    var connectJournalPayload: Map<String, Any?> = emptyMap()
    Log.i(
      "ChatEngine",
      "connect start transportMode=$transportMode target=${resolvedTarget.take(200)} userTopic=$userTopic hasAuthToken=${!authToken.isNullOrBlank()} hasExistingClient=${phoenixClient != null}",
    )
    synchronized(lock) {
      Log.d("ChatEngine", "connect stage=entered_lock userTopic=$userTopic signatureHash=${signature.hashCode()}")
      if (phoenixClient != null && nativeSocketSignature != signature) {
        clientToDisconnect = phoenixClient
        phoenixClient = null
        nativePresenceActive = false
        nativeUserJoinRef = null
        nativeUserTopic = null
        nativeChatJoinRefsByRef.clear()
        nativeJoinedChatIds.clear()
        nativePendingMessagePushRefs.clear()
        nativePendingEditPushRefs.clear()
        nativePendingDeletePushRefs.clear()
        pendingOutboundDraftsByMessageId.clear()
        pendingOutboundQueueByChat.clear()
        nativeTypingStateByChatId.clear()
        peerTypingUserIdsByChatId.clear()
        nativeRecordingStateByChatId.clear()
        pinnedMessagesByChatId.clear()
        pinnedFetchInFlightChatIds.clear()
        historyLoadingChats.clear()
        liveMessageRowsByChat.clear()
        deletedMessageIdsByChat.clear()
      }
      if (phoenixClient == null) {
        val callbacks = object : ChatTransportCallbacks {
          override fun onOpen() = onNativeSocketOpen(userTopic)
          override fun onClosed(code: Int, reason: String?) = onNativeSocketClosed(code, reason)
          override fun onError(error: String) = onNativeSocketError(error)
          override fun onEvent(frame: ChatTransportEvent) = onNativeSocketEvent(frame)
        }
        phoenixClient =
          if (transportMode == "bridge_text" && !bridgeBaseUrl.isNullOrBlank()) {
            BlackoutChatTransport(
              bridgeBaseUrl = bridgeBaseUrl,
              authToken = authToken,
              userId = userId ?: userTopic.removePrefix("user:"),
              activeBridgeId = normalized(config["activeBridgeId"]),
              bridgeBundle = config["bridgeBundle"] as? Map<String, Any?>,
              callbacks = callbacks,
            )
          } else if (transportMode == "packet_mesh" && packetProxyPort != null) {
            ChatPacketTransport(
              socketUrl = socketUrl!!,
              authToken = authToken,
              proxyHost = packetProxyHost,
              proxyPort = packetProxyPort,
              callbacks = callbacks,
            )
          } else {
            ChatPhoenixClient(
              socketUrl = socketUrl!!,
              params = emptyMap(),
              authToken = authToken,
              callbacks = callbacks,
            )
          }
        nativeSocketSignature = signature
      }
      Log.d("ChatEngine", "connect stage=client_ready userTopic=$userTopic hasClient=${phoenixClient != null}")
      nativeUserTopic = userTopic
      state["connected"] = false
      state["state"] = "connecting-native-presence"
      state["updatedAt"] = System.currentTimeMillis()
      state["transportMode"] = transportMode
      putNullableStateLocked("activeBridgeId", normalized(config["activeBridgeId"]))
      putNullableStateLocked("activePacketBridgeId", normalized(config["activePacketBridgeId"]))
      putNullableStateLocked("bridgeBaseUrl", bridgeBaseUrl)
      putNullableStateLocked("packetProxyPort", packetProxyPort)
      state["note"] =
        if (transportMode == "bridge_text") {
          "ChatEngine blackout bridge connecting"
        } else if (transportMode == "packet_mesh") {
          "ChatEngine Packet mesh connecting"
        } else {
          "ChatEngine native Phoenix presence connecting"
        }
      state["presenceSource"] = if (nativePresenceActive) "native" else "shadow"
      connectJournalPayload =
        mapOf(
          "topic" to userTopic,
          "transportMode" to transportMode,
          "bridgeBaseUrl" to bridgeBaseUrl,
          "packetProxyPort" to packetProxyPort,
        )
      clientToConnect = phoenixClient
      openChatIdsSnapshot = openChatChannels.keys.toList()
      Log.d(
        "ChatEngine",
        "connect stage=lock_exit_ready userTopic=$userTopic hasClient=${clientToConnect != null} openChatIds=$openChatIdsSnapshot",
      )
    }

    appendJournalLocked("connect-native", connectJournalPayload)
    emitChangeLocked("connectionStateChanged", null, null)
    Log.i(
      "ChatEngine",
      "connect dispatch transportMode=$transportMode userTopic=$userTopic openChatIds=$openChatIdsSnapshot hasClient=${clientToConnect != null}",
    )
    clientToDisconnect?.disconnect()
    clientToConnect?.connect()
    return getStatus()
  }

  fun disconnect(): Map<String, Any?> {
    val clientToDisconnect: ChatRealtimeTransport?
    val result = synchronized(lock) {
      clientToDisconnect = phoenixClient
      phoenixClient = null
      nativePresenceActive = false
      nativeUserJoinRef = null
      nativeUserTopic = null
      nativeChatJoinRefsByRef.clear()
      nativeJoinedChatIds.clear()
      nativePendingMessagePushRefs.clear()
      nativePendingEditPushRefs.clear()
      nativePendingDeletePushRefs.clear()
      pendingOutboundDraftsByMessageId.clear()
      pendingOutboundQueueByChat.clear()
      onlineUsers.clear()
      lastSeenByUserId.clear()
      surfaceBindings.clear()
      openChatChannels.clear()
      receiptIndex.clear()
      localStatusIndex.clear()
      nativeTypingStateByChatId.clear()
      peerTypingUserIdsByChatId.clear()
      nativeRecordingStateByChatId.clear()
      pinnedMessagesByChatId.clear()
      pinnedFetchInFlightChatIds.clear()
      historyRowsByChat.clear()
      historyLoadingChats.clear()
      liveMessageRowsByChat.clear()
      deletedMessageIdsByChat.clear()
      chatPeerUserIdsByChatId.clear()
      friendPublicKeysByUserId.clear()
      configuredUserId = null
      // Clear cached private key on disconnect to reduce memory exposure.
      cachedDecryptPrivateKey = null
      cachedDecryptPrivateKeyPem = null
      cachedDecryptKeyTimestampMs = 0L
      state["connected"] = false
      state["state"] = "disconnected"
      state["updatedAt"] = System.currentTimeMillis()
      state["presenceSource"] = "shadow"
      appendJournalLocked("disconnect", emptyMap())
      val snapshot = statusSnapshotLocked()
      emitChangeLocked("connectionStateChanged", null, null)
      snapshot
    }
    clientToDisconnect?.disconnect()
    return result
  }

  fun bindSurface(payload: Map<String, Any?>): Map<String, Any?> {
    val surfaceId = normalized(payload["surfaceId"] ?: payload["engineSurfaceId"]) ?: return getStatus()
    val snapshot = synchronized(lock) {
      surfaceBindings[surfaceId] = SurfaceBinding(
        surfaceId = surfaceId,
        chatId = normalized(payload["chatId"]),
        myUserId = normalizedUpper(payload["myUserId"]),
        peerUserId = normalizedUpper(payload["peerUserId"]),
      )
      state["updatedAt"] = System.currentTimeMillis()
      appendJournalLocked("bind-surface", payload)
      val result = statusSnapshotLocked()
      emitChangeLocked("surfaceBindingChanged", surfaceBindings[surfaceId]?.chatId, null)
      result
    }
    ensureNativeTransport("bind_surface")
    return snapshot
  }

  fun unbindSurface(payload: Map<String, Any?>): Map<String, Any?> {
    val surfaceId = normalized(payload["surfaceId"] ?: payload["engineSurfaceId"]) ?: return getStatus()
    synchronized(lock) {
      surfaceBindings.remove(surfaceId)
      state["updatedAt"] = System.currentTimeMillis()
      appendJournalLocked("unbind-surface", mapOf("surfaceId" to surfaceId))
      val result = statusSnapshotLocked()
      emitChangeLocked("surfaceBindingChanged", null, null)
      return result
    }
  }

  fun openChatChannel(payload: Map<String, Any?>): Map<String, Any?> =
    synchronized(lock) {
      val resolvedChatId = normalized(payload["chatId"] ?: payload["chat_id"])
      resolvedChatId?.let { chatId ->
        openChatChannels[chatId] = (openChatChannels[chatId] ?: 0) + 1
        Log.i(
          "ChatEngine",
          "openChatChannel chatId=$chatId count=${openChatChannels[chatId] ?: 0} ${transportDebugStateLocked(chatId)}",
        )
        joinNativeChatTopicIfNeededLocked(chatId)
      }
      appendJournalLocked("open-chat-channel", payload)
      state["updatedAt"] = System.currentTimeMillis()
      val result = statusSnapshotLocked()
      emitChangeLocked("chatChannelStateChanged", resolvedChatId, null)
      result
    }.also {
      ensureNativeTransport("open_chat_channel")
    }

  fun closeChatChannel(payload: Map<String, Any?>): Map<String, Any?> =
    synchronized(lock) {
      val resolvedChatId = normalized(payload["chatId"] ?: payload["chat_id"])
      resolvedChatId?.let { chatId ->
        val current = openChatChannels[chatId] ?: 0
        when {
          current <= 1 -> {
            openChatChannels.remove(chatId)
            nativeJoinedChatIds.remove(chatId)
            peerTypingUserIdsByChatId.remove(chatId)
            phoenixClient?.leave(chatTopic(chatId))
          }
          else -> openChatChannels[chatId] = current - 1
        }
      }
      appendJournalLocked("close-chat-channel", payload)
      state["updatedAt"] = System.currentTimeMillis()
      val result = statusSnapshotLocked()
      emitChangeLocked("chatChannelStateChanged", resolvedChatId, null)
      result
    }

  fun sendDeliveryReceipt(payload: Map<String, Any?>): Map<String, Any?> =
    sendReceipt(payload, "delivered", "delivery-receipt", "delivery-receipt")

  fun sendReadReceipt(payload: Map<String, Any?>): Map<String, Any?> =
    sendReceipt(payload, "read", "read-receipt", "read-receipt")

  fun sendTypingState(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_chat")
    val typing = when (val raw = payload["typing"]) {
      is Boolean -> raw
      is Number -> raw.toInt() != 0
      is String -> raw.equals("true", ignoreCase = true) || raw == "1" || raw.equals("yes", ignoreCase = true) || raw.equals("on", ignoreCase = true)
      else -> false
    }
    return synchronized(lock) {
      Log.d(
        "ChatEngine",
        "sendTypingState start chatId=$chatId typing=$typing ${transportDebugStateLocked(chatId)}",
      )
      if (isBridgeTextModeLocked()) {
        return@synchronized mapOf("accepted" to false, "reason" to "typing_disabled_in_blackout", "typing" to typing)
      }
      if (nativeTypingStateByChatId[chatId] == typing) {
        Log.d(
          "ChatEngine",
          "sendTypingState deduped chatId=$chatId typing=$typing ${transportDebugStateLocked(chatId)}",
        )
        return@synchronized mapOf("accepted" to true, "transport" to "native", "deduped" to true, "typing" to typing)
      }
      nativeTypingStateByChatId[chatId] = typing
      val client = phoenixClient ?: run {
        Log.w(
          "ChatEngine",
          "sendTypingState blocked reason=no_native_socket chatId=$chatId typing=$typing ${transportDebugStateLocked(chatId)}",
        )
        ensureNativeTransportAsync("typing_no_socket")
        return@synchronized mapOf("accepted" to false, "reason" to "no_native_socket", "typing" to typing)
      }
      if (!nativeJoinedChatIds.contains(chatId) || state["connected"] != true) {
        Log.w(
          "ChatEngine",
          "sendTypingState blocked reason=chat_not_joined chatId=$chatId typing=$typing ${transportDebugStateLocked(chatId)}",
        )
        joinNativeChatTopicIfNeededLocked(chatId)
        ensureNativeTransportAsync("typing_chat_not_joined")
        return@synchronized mapOf("accepted" to false, "reason" to "chat_not_joined", "typing" to typing)
      }
      val userId = normalized(getConfigValueLocked("userId")) ?: "me"
      val event = if (typing) "typing" else "stop-typing"
      val ref = client.push(chatTopic(chatId), event, mapOf("userId" to userId))
      Log.i(
        "ChatEngine",
        "sendTypingState pushed chatId=$chatId typing=$typing ref=$ref event=$event userId=$userId ${transportDebugStateLocked(chatId)}",
      )
      appendJournalLocked("native-$event", mapOf("chatId" to chatId, "ref" to ref, "typing" to typing))
      state["updatedAt"] = System.currentTimeMillis()
      emitChangeLocked("typingStateSent", chatId, null)
      mapOf("accepted" to true, "transport" to "native", "ref" to ref, "typing" to typing)
    }
  }

  fun sendRecordingState(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_chat")
    val isRecording = when (val raw = payload["isRecording"] ?: payload["recording"]) {
      is Boolean -> raw
      is Number -> raw.toInt() != 0
      is String -> raw.equals("true", ignoreCase = true) || raw == "1" || raw.equals("yes", ignoreCase = true) || raw.equals("on", ignoreCase = true)
      else -> false
    }
    val isLocked = when (val raw = payload["isLocked"] ?: payload["locked"]) {
      is Boolean -> raw
      is Number -> raw.toInt() != 0
      is String -> raw.equals("true", ignoreCase = true) || raw == "1" || raw.equals("yes", ignoreCase = true) || raw.equals("on", ignoreCase = true)
      else -> false
    }
    val mode = normalized(payload["mode"]) ?: "voice"
    return synchronized(lock) {
      if (isBridgeTextModeLocked()) {
        return@synchronized mapOf(
          "accepted" to false,
          "reason" to "recording_disabled_in_blackout",
          "isRecording" to isRecording,
        )
      }
      if (nativeRecordingStateByChatId[chatId] == isRecording) {
        return@synchronized mapOf("accepted" to true, "transport" to "native", "deduped" to true, "isRecording" to isRecording)
      }
      nativeRecordingStateByChatId[chatId] = isRecording
      val client = phoenixClient ?: run {
        ensureNativeTransportAsync("recording_no_socket")
        return@synchronized mapOf("accepted" to false, "reason" to "no_native_socket", "isRecording" to isRecording)
      }
      if (!nativeJoinedChatIds.contains(chatId) || state["connected"] != true) {
        joinNativeChatTopicIfNeededLocked(chatId)
        ensureNativeTransportAsync("recording_chat_not_joined")
        return@synchronized mapOf("accepted" to false, "reason" to "chat_not_joined", "isRecording" to isRecording)
      }
      val userId = normalized(getConfigValueLocked("userId")) ?: "me"
      val event = if (isRecording) "recording" else "stop-recording"
      val wirePayload = linkedMapOf<String, Any?>("userId" to userId)
      if (isRecording) {
        wirePayload["mode"] = mode
        wirePayload["isLocked"] = isLocked
        if (payload["vad"] != null) wirePayload["vad"] = payload["vad"]
      }
      val ref = client.push(chatTopic(chatId), event, wirePayload)
      appendJournalLocked(
        "native-$event",
        mapOf("chatId" to chatId, "ref" to ref, "isRecording" to isRecording, "isLocked" to isLocked, "mode" to mode),
      )
      state["updatedAt"] = System.currentTimeMillis()
      emitChangeLocked("recordingStateSent", chatId, null)
      mapOf("accepted" to true, "transport" to "native", "ref" to ref, "isRecording" to isRecording)
    }
  }

  fun retryOutgoingMessage(payload: Map<String, Any?>): Map<String, Any?> {
    val messageId = normalized(payload["messageId"] ?: payload["message_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_message")
    return synchronized(lock) {
      canceledOutboundMessageIds.remove(messageId)
      val draft = pendingOutboundDraftsByMessageId[messageId]
        ?: return@synchronized mapOf("accepted" to false, "reason" to "missing_draft", "messageId" to messageId)
      val chatId =
        normalized(payload["chatId"] ?: payload["chat_id"])
          ?: normalized(draft["chatId"] ?: draft["chat_id"])
          ?: return@synchronized mapOf("accepted" to false, "reason" to "invalid_chat", "messageId" to messageId)
      queueOutboundDraftLocked(chatId, messageId, draft, "manual_retry")
      scheduleReplayQueuedOutboundLocked(chatId, "manual_retry")
      mapOf("accepted" to true, "queued" to true, "messageId" to messageId, "state" to "pending")
    }
  }

  fun cancelOutgoingMessage(payload: Map<String, Any?>): Map<String, Any?> {
    val messageId = normalized(payload["messageId"] ?: payload["message_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_message")
    return synchronized(lock) {
      val draft = pendingOutboundDraftsByMessageId[messageId]
      val chatId =
        normalized(payload["chatId"] ?: payload["chat_id"])
          ?: normalized(draft?.get("chatId") ?: draft?.get("chat_id"))
          ?: return@synchronized mapOf("accepted" to false, "reason" to "invalid_chat", "messageId" to messageId)
      val hadActiveUpload = activeMediaUploadCallsByMessageId.remove(messageId)?.also { it.cancel() } != null
      canceledOutboundMessageIds.add(messageId)
      removeQueuedOutboundDraftLocked(chatId, messageId, dropDraft = true)
      setLiveMessageUploadProgressLocked(chatId, messageId, null)
      upsertLocalStatusLocked(chatId, messageId, "error")
      appendJournalLocked(
        "native-outgoing-cancel",
        mapOf("chatId" to chatId, "messageId" to messageId, "hadActiveUpload" to hadActiveUpload),
      )
      emitChangeLocked("outgoingMessageCanceled", chatId, messageId)
      emitChangeLocked("chatMessageChanged", chatId, messageId)
      emitChangeLocked("messageStatusChanged", chatId, messageId)
      mapOf("accepted" to true, "messageId" to messageId, "state" to "canceled")
    }
  }

  fun sendMessage(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: run {
        Log.w("ChatEngine", "sendMessage rejected reason=invalid_chat payloadKeys=${payload.keys}")
        return mapOf("accepted" to false, "reason" to "invalid_chat")
      }
    val type = (normalized(payload["type"]) ?: "text").lowercase()
    val text = normalized(payload["text"]) ?: ""
    val supportedTypes = setOf(
      "text", "image", "gif", "file", "voice", "video", "music", "location", "contact",
      "sticker",
    )
    if (!supportedTypes.contains(type)) {
      Log.w("ChatEngine", "sendMessage rejected reason=unsupported_type chatId=$chatId type=$type")
      return mapOf("accepted" to false, "reason" to "unsupported_type", "type" to type)
    }
    if (synchronized(lock) { isBridgeTextModeLocked() && type != "text" }) {
      return mapOf("accepted" to false, "reason" to "media_disabled_in_blackout", "type" to type)
    }
    val metadata = payload["metadata"] as? Map<*, *> ?: emptyMap<String, Any?>()
    fun meta(key: String, vararg aliases: String): Any? {
      payload[key]?.let { return it }
      aliases.forEach { alias -> payload[alias]?.let { return it } }
      metadata[key]?.let { return it }
      aliases.forEach { alias -> metadata[alias]?.let { return it } }
      return null
    }
    var mediaUrl = normalized(meta("mediaUrl", "media_url", "previewUrl", "preview_url"))
    val localPlaybackMediaUrl = mediaUrl?.takeIf { isLocalMediaUri(it) }
    var fileName = normalized(meta("fileName", "file_name"))
    var fileSize = parseLongValue(meta("fileSize", "file_size"))
    val latitude = parseDoubleValue(meta("latitude"))
    val longitude = parseDoubleValue(meta("longitude"))
    val duration = parseDoubleValue(meta("duration"))
    val width = parseLongValue(meta("width"))
    val height = parseLongValue(meta("height"))
    val caption = normalized(meta("caption"))
    val thumbnailBase64 = normalized(meta("thumbnailBase64", "thumbnail_base64"))
    var mediaKey = normalized(meta("mediaKey", "media_key"))
    val contact = meta("contact")
    val viewOnce = meta("viewOnce", "view_once")
    val isVideoNote = meta("isVideoNote", "is_video_note")
    val waveform = meta("waveform")
    val stickerId = normalized(meta("stickerId"))
    val stickerPackId = normalized(meta("stickerPackId", "packId", "pack_id"))
    val stickerBundleFileName = normalized(
      meta("stickerBundleFileName", "bundleFileName", "bundle_file_name"),
    )
    val stickerEmoji = normalized(meta("emoji"))
    if (type == "text" && text.isBlank()) {
      Log.w("ChatEngine", "sendMessage rejected reason=empty_text chatId=$chatId")
      return mapOf("accepted" to false, "reason" to "empty_text")
    }
    if (setOf("image", "gif", "file", "voice", "video", "music").contains(type)) {
      if (mediaUrl.isNullOrBlank()) {
        Log.w(
          "ChatEngine",
          "sendMessage rejected reason=missing_media_url chatId=$chatId type=$type",
        )
        return mapOf("accepted" to false, "reason" to "missing_media_url", "type" to type)
      }
    }
    if (type == "location" && (latitude == null || longitude == null)) {
      Log.w("ChatEngine", "sendMessage rejected reason=invalid_location chatId=$chatId")
      return mapOf("accepted" to false, "reason" to "invalid_location")
    }
    if (type == "contact" && contact == null) {
      Log.w("ChatEngine", "sendMessage rejected reason=missing_contact chatId=$chatId")
      return mapOf("accepted" to false, "reason" to "missing_contact")
    }
    val messageId = normalized(payload["messageId"] ?: payload["message_id"]) ?: java.util.UUID.randomUUID().toString().lowercase()
    val timestampMs =
      parseLongValue(payload["timestampMs"] ?: payload["timestamp"] ?: payload["timestamp_ms"])
        ?: System.currentTimeMillis()
    val replyToId =
      normalized(payload["replyToId"] ?: payload["reply_to_id"])
        ?: normalized(metadata["replyToId"] ?: metadata["reply_to_id"])
    val peerUserIdHint = normalizedUpper(payload["peerUserId"] ?: payload["peer_user_id"])
    Log.i(
      "ChatEngine",
      "sendMessage start chatId=$chatId messageId=$messageId type=$type textLen=${text.length} hasPeerHint=${peerUserIdHint != null} mediaLocal=${mediaUrl?.let { isLocalMediaUri(it) } ?: false}",
    )

    return synchronized(lock) {
      canceledOutboundMessageIds.remove(messageId)
      val effectivePayload = LinkedHashMap(payload)
      val isGroup = (payload["isGroup"] as? Boolean == true) || (payload["isGroupOrChannel"] as? Boolean == true)
      Log.i("ChatEngine", "sendMessage START chatId=$chatId messageId=$messageId isGroup=$isGroup")

      if (!peerUserIdHint.isNullOrBlank()) {
        chatPeerUserIdsByChatId[chatId] = peerUserIdHint
      }
      val peerUserId = peerUserIdHint ?: chatPeerUserIdsByChatId[chatId]

      // ── Build + emit optimistic row FIRST so message bubble appears instantly ──
      val optimisticStartMs = System.currentTimeMillis()
      val decryptedFields = linkedMapOf<String, Any?>("text" to text)
      if (!mediaUrl.isNullOrBlank()) decryptedFields["mediaUrl"] = mediaUrl
      if (!localPlaybackMediaUrl.isNullOrBlank()) {
        decryptedFields["localMediaUrl"] = localPlaybackMediaUrl
      }
      if (!fileName.isNullOrBlank()) decryptedFields["fileName"] = fileName
      if (fileSize != null) decryptedFields["fileSize"] = fileSize
      if (latitude != null) decryptedFields["latitude"] = latitude
      if (longitude != null) decryptedFields["longitude"] = longitude
      if (duration != null) decryptedFields["duration"] = duration
      if (width != null) decryptedFields["width"] = width
      if (height != null) decryptedFields["height"] = height
      if (!replyToId.isNullOrBlank()) decryptedFields["replyToId"] = replyToId
      if (contact != null) decryptedFields["contact"] = contact
      if (!caption.isNullOrBlank()) decryptedFields["caption"] = caption
      if (!thumbnailBase64.isNullOrBlank()) decryptedFields["thumbnailBase64"] = thumbnailBase64
      if (!mediaKey.isNullOrBlank()) decryptedFields["mediaKey"] = mediaKey
      if (viewOnce != null) decryptedFields["viewOnce"] = viewOnce
      if (isVideoNote != null) decryptedFields["isVideoNote"] = isVideoNote
      if (waveform != null) decryptedFields["waveform"] = waveform
      if (!stickerId.isNullOrBlank()) decryptedFields["stickerId"] = stickerId
      if (!stickerPackId.isNullOrBlank()) decryptedFields["stickerPackId"] = stickerPackId
      if (!stickerBundleFileName.isNullOrBlank()) {
        decryptedFields["stickerBundleFileName"] = stickerBundleFileName
      }
      if (!stickerEmoji.isNullOrBlank()) decryptedFields["emoji"] = stickerEmoji
      val optimisticRow = buildLiveRowPayloadLocked(
        chatId = chatId,
        messageId = messageId,
        fromId = normalized(getConfigValueLocked("userId")),
        type = type,
        timestampMs = timestampMs,
        encryptedContent = null,
        decryptedFields = decryptedFields,
      ).toMutableMap()
      val optimisticMessage = (optimisticRow["message"] as? Map<String, Any?>)?.toMutableMap() ?: linkedMapOf()
      optimisticMessage["status"] = "sending"
      if (!replyToId.isNullOrBlank()) optimisticMessage["replyToId"] = replyToId
      optimisticRow["message"] = optimisticMessage
      upsertLiveMessageRowLocked(chatId, messageId, optimisticRow)
      upsertLocalStatusLocked(chatId, messageId, "sending")
      emitChangeLocked("chatMessageInserted", chatId, messageId)
      emitChangeLocked("messageStatusChanged", chatId, messageId)
      val shouldSeedNativeUploadProgress =
        setOf("image", "gif", "file", "voice", "video", "music").contains(type) &&
          !mediaUrl.isNullOrBlank() &&
          isLocalMediaUri(mediaUrl!!)
      if (shouldSeedNativeUploadProgress) {
        setLiveMessageUploadProgressLocked(chatId, messageId, 0.02f)
      }
      Log.i("ChatEngine", "sendMessage optimistic row emitted in ${System.currentTimeMillis() - optimisticStartMs}ms chatId=$chatId messageId=$messageId")

      val apiBaseUrl = apiBaseUrlLocked()
      val token = authHeaderTokenLocked()
      val userId = normalized(getConfigValueLocked("userId"))
      val myPublicKeyPem = normalized(getConfigValueLocked("publicKeyPem") ?: getConfigValueLocked("publicKey"))

      Thread { try {
        // ── Now resolve friend public key (may do synchronous HTTP — no longer blocks UI) ──
        val keyResolveStartMs = System.currentTimeMillis()
        val friendPublicKey = if (isGroup) null else {
          synchronized(lock) { resolveFriendPublicKeyLocked(chatId, peerUserId) }
            ?: run {
              Log.w(
                "ChatEngine",
                "sendMessage queued reason=missing_friend_key chatId=$chatId messageId=$messageId peerUserId=$peerUserId keyResolveMs=${System.currentTimeMillis() - keyResolveStartMs}",
              )
              synchronized(lock) {
                pendingOutboundDraftsByMessageId[messageId] = LinkedHashMap(effectivePayload)
                upsertLocalStatusLocked(chatId, messageId, "pending")
                queueOutboundDraftLocked(chatId, messageId, effectivePayload, "missing_friend_key")
                emitChangeLocked("messageStatusChanged", chatId, messageId)
                loadChatHistoryIfNeededLocked(chatId, force = true)
                ensureNativeTransportAsync("send_missing_friend_key")
              }
              return@Thread
            }
        }
        Log.i("ChatEngine", "sendMessage keyResolved in ${System.currentTimeMillis() - keyResolveStartMs}ms chatId=$chatId messageId=$messageId hasKey=${friendPublicKey != null}")

        val needsUpload =
          setOf("image", "gif", "file", "voice", "video", "music").contains(type) &&
            !mediaUrl.isNullOrBlank() &&
            isLocalMediaUri(mediaUrl!!)

        var finalMediaUrl = mediaUrl
        var finalFileName = fileName
        var finalFileSize = fileSize
        var finalMediaKey = mediaKey

        if (needsUpload) {
          if (apiBaseUrl.isNullOrBlank() || token.isNullOrBlank() || userId.isNullOrBlank()) {
            synchronized(lock) {
              setLiveMessageUploadProgressLocked(chatId, messageId, null)
              upsertLocalStatusLocked(chatId, messageId, "pending")
              queueOutboundDraftLocked(chatId, messageId, effectivePayload, "missing_upload_config")
              appendJournalLocked(
                "native-media-upload-error",
                mapOf("chatId" to chatId, "messageId" to messageId, "reason" to "missing_upload_config"),
              )
              emitChangeLocked("messageStatusChanged", chatId, messageId)
            }
            return@Thread
          }
          Log.i(
            "ChatEngine",
            "sendMessage uploadStart chatId=$chatId messageId=$messageId type=$type localUri=${mediaUrl?.take(160)} fileName=${fileName ?: "-"}",
          )
          synchronized(lock) {
            appendJournalLocked(
              "native-media-upload-start",
              mapOf("chatId" to chatId, "messageId" to messageId, "type" to type),
            )
            setLiveMessageUploadProgressLocked(chatId, messageId, minimumNativeUploadProgress)
          }

          val uploadResult = uploadLocalMediaLocked(
            localUri = mediaUrl!!,
            messageType = type,
            fileNameHint = fileName,
            userId = userId,
            token = token,
            apiBaseUrl = apiBaseUrl,
            messageId = messageId,
          ) { p ->
            synchronized(lock) {
              if (canceledOutboundMessageIds.contains(messageId)) return@synchronized
              setLiveMessageUploadProgressLocked(
                chatId,
                messageId,
                p.coerceIn(minimumNativeUploadProgress, 1f),
              )
            }
          }

          synchronized(lock) {
            when (uploadResult) {
              is LocalMediaUploadOutcome.Success -> {
                if (canceledOutboundMessageIds.contains(messageId)) {
                  setLiveMessageUploadProgressLocked(chatId, messageId, null)
                  upsertLocalStatusLocked(chatId, messageId, "error")
                  emitChangeLocked("chatMessageChanged", chatId, messageId)
                  emitChangeLocked("messageStatusChanged", chatId, messageId)
                  canceledOutboundMessageIds.remove(messageId)
                  return@Thread
                }
                finalMediaUrl = uploadResult.value.remoteUrl
                if (finalFileName.isNullOrBlank()) finalFileName = uploadResult.value.fileName
                if (finalFileSize == null) finalFileSize = uploadResult.value.fileSize
                if (finalMediaKey.isNullOrBlank()) finalMediaKey = uploadResult.value.mediaKey
                val nextMetadata = linkedMapOf<String, Any?>()
                val existingMetadata = payload["metadata"] as? Map<*, *> ?: emptyMap<String, Any?>()
                existingMetadata.forEach { (k, v) -> if (k != null) nextMetadata[k.toString()] = v }
                nextMetadata["mediaUrl"] = finalMediaUrl
                if (!localPlaybackMediaUrl.isNullOrBlank()) {
                  nextMetadata["localMediaUrl"] = localPlaybackMediaUrl
                }
                if (!finalFileName.isNullOrBlank()) nextMetadata["fileName"] = finalFileName
                if (finalFileSize != null) nextMetadata["fileSize"] = finalFileSize
                if (!finalMediaKey.isNullOrBlank()) nextMetadata["mediaKey"] = finalMediaKey
                effectivePayload["metadata"] = nextMetadata
                effectivePayload["chatId"] = chatId
                effectivePayload["messageId"] = messageId
                effectivePayload["type"] = type
                effectivePayload["text"] = text
                optimisticMessage["mediaUrl"] = finalMediaUrl
                if (!localPlaybackMediaUrl.isNullOrBlank()) {
                  optimisticMessage["localMediaUrl"] = localPlaybackMediaUrl
                }
                if (!finalFileName.isNullOrBlank()) optimisticMessage["fileName"] = finalFileName
                if (finalFileSize != null) optimisticMessage["fileSize"] = finalFileSize
                if (!finalMediaKey.isNullOrBlank()) optimisticMessage["mediaKey"] = finalMediaKey
                val optimisticMetadata =
                  (optimisticMessage["metadata"] as? MutableMap<String, Any?>) ?: linkedMapOf()
                if (!finalMediaKey.isNullOrBlank()) optimisticMetadata["mediaKey"] = finalMediaKey
                if (!localPlaybackMediaUrl.isNullOrBlank()) {
                  optimisticMetadata["localMediaUrl"] = localPlaybackMediaUrl
                }
                optimisticMessage["metadata"] = optimisticMetadata
                optimisticRow["message"] = optimisticMessage
                upsertLiveMessageRowLocked(chatId, messageId, optimisticRow)
                setLiveMessageUploadProgressLocked(chatId, messageId, 1.0f)
                appendJournalLocked(
                  "native-media-upload-ok",
                  mapOf("chatId" to chatId, "messageId" to messageId, "url" to finalMediaUrl),
                )
                Log.d(
                  "ChatEngine",
                  "voice upload complete chatId=$chatId messageId=$messageId remoteUrl=${finalMediaUrl?.take(120)} localPlayback=${localPlaybackMediaUrl?.take(120)} type=$type",
                )
              }
              is LocalMediaUploadOutcome.Failure -> {
                val reason = uploadResult.reason
                val shouldQueue = setOf("upload_failed", "upload_timeout", "missing_upload_config").contains(reason)
                Log.w(
                  "ChatEngine",
                  "sendMessage uploadFailed chatId=$chatId messageId=$messageId type=$type reason=$reason retryable=$shouldQueue localUri=${mediaUrl?.take(160)}",
                )
                setLiveMessageUploadProgressLocked(chatId, messageId, null)
                upsertLocalStatusLocked(chatId, messageId, if (shouldQueue) "pending" else "error")
                appendJournalLocked(
                  "native-media-upload-error",
                  mapOf("chatId" to chatId, "messageId" to messageId, "reason" to reason),
                )
                emitChangeLocked("messageStatusChanged", chatId, messageId)
                if (shouldQueue) {
                  queueOutboundDraftLocked(chatId, messageId, effectivePayload, reason)
                }
                canceledOutboundMessageIds.remove(messageId)
                return@Thread
              }
            }
          }
        }

        synchronized(lock) {
          if (canceledOutboundMessageIds.contains(messageId)) {
            setLiveMessageUploadProgressLocked(chatId, messageId, null)
            upsertLocalStatusLocked(chatId, messageId, "error")
            emitChangeLocked("chatMessageChanged", chatId, messageId)
            emitChangeLocked("messageStatusChanged", chatId, messageId)
            canceledOutboundMessageIds.remove(messageId)
            return@Thread
          }
        }

        val encryptStartMs = System.currentTimeMillis()
        val fullPayload = linkedMapOf<String, Any?>("text" to text)
        if (!finalMediaUrl.isNullOrBlank()) fullPayload["mediaUrl"] = finalMediaUrl
        if (!finalMediaKey.isNullOrBlank()) fullPayload["mediaKey"] = finalMediaKey
        if (!finalFileName.isNullOrBlank()) fullPayload["fileName"] = finalFileName
        if (finalFileSize != null) fullPayload["fileSize"] = finalFileSize
        if (latitude != null) fullPayload["latitude"] = latitude
        if (longitude != null) fullPayload["longitude"] = longitude
        if (duration != null) fullPayload["duration"] = duration
        if (width != null) fullPayload["width"] = width
        if (height != null) fullPayload["height"] = height
        if (!replyToId.isNullOrBlank()) fullPayload["replyToId"] = replyToId
        if (contact != null) fullPayload["contact"] = contact
        if (!caption.isNullOrBlank()) fullPayload["caption"] = caption
        if (!thumbnailBase64.isNullOrBlank()) fullPayload["thumbnailBase64"] = thumbnailBase64
        if (viewOnce != null) fullPayload["viewOnce"] = viewOnce
        if (isVideoNote != null) fullPayload["isVideoNote"] = isVideoNote
        if (waveform != null) fullPayload["waveform"] = waveform
        if (!stickerId.isNullOrBlank()) fullPayload["stickerId"] = stickerId
        if (!stickerPackId.isNullOrBlank()) fullPayload["stickerPackId"] = stickerPackId
        if (!stickerBundleFileName.isNullOrBlank()) {
          fullPayload["stickerBundleFileName"] = stickerBundleFileName
        }
        if (!stickerEmoji.isNullOrBlank()) fullPayload["emoji"] = stickerEmoji
        val fullPayloadString = JSONObject(fullPayload).toString()

        val recipientPublicKey = if (!isGroup) {
          friendPublicKey ?: run {
             synchronized(lock) {
                upsertLocalStatusLocked(chatId, messageId, "error")
                emitChangeLocked("messageStatusChanged", chatId, messageId)
             }
             return@Thread
          }
        } else {
          null
        }

        val encryptedContent = if (isGroup) fullPayloadString else {
          val directRecipientPublicKey = recipientPublicKey ?: run {
            synchronized(lock) {
              upsertLocalStatusLocked(chatId, messageId, "error")
              emitChangeLocked("messageStatusChanged", chatId, messageId)
            }
            return@Thread
          }
          try {
            chatEngineEncryptHybridMessage(directRecipientPublicKey, fullPayloadString, myPublicKeyPem ?: "")
          } catch (e: Throwable) {
            synchronized(lock) {
              upsertLocalStatusLocked(chatId, messageId, "error")
              appendJournalLocked(
                "native-send-message-error",
                mapOf("chatId" to chatId, "messageId" to messageId, "reason" to "encrypt_failed", "error" to (e.message ?: "encrypt_failed")),
              )
              emitChangeLocked("messageStatusChanged", chatId, messageId)
            }
            return@Thread
          }
        }

        val pushPreview = text.trim().let { trimmed ->
          if (trimmed.isNotEmpty()) {
            if (trimmed.length <= 160) trimmed else trimmed.take(159) + "…"
          } else {
            when (type) {
              "image" -> "Photo"
              "video" -> "Video"
              "voice" -> "Voice message"
              "music" -> "Audio"
              "file" -> "File"
              "location" -> "Location"
              "contact" -> "Contact"
              "gif" -> "GIF"
              "sticker" -> "Sticker"
              else -> ""
            }
          }
        }

        // A 1:1 DM with a peer key is the one path whose encryptedContent is real
        // ciphertext, so a cleartext copy beside it was a leak. iOS omits it there too.
        val isRealE2EDM = !isGroup && friendPublicKey != null
        val wirePayload = linkedMapOf<String, Any?>(
          "id" to messageId,
          "fromId" to userId,
          "encryptedContent" to encryptedContent,
          "timestamp" to timestampMs,
          "type" to type,
          // Content-free stand-in: lets the server shape a push without reading the text.
          "pushKind" to type,
          "mediaUrl" to null,
          "fileName" to null,
          "latitude" to null,
          "longitude" to null,
        )
        if (!isRealE2EDM) wirePayload["pushPreview"] = pushPreview
        if ((payload["agentMention"] as? Boolean) == true) {
          wirePayload["agentMention"] = true
          (payload["agentText"] as? String)?.takeIf { it.isNotBlank() }?.let {
            wirePayload["agentText"] = it
          }
        }
        (payload["mentionedAgentUsername"] as? String)?.takeIf { it.isNotBlank() }?.let {
          wirePayload["mentionedAgentUsername"] = it
          (payload["agentText"] as? String)?.takeIf { value -> value.isNotBlank() }?.let { agentText ->
            wirePayload["agentText"] = agentText
          }
        }

        synchronized(lock) {
          if (canceledOutboundMessageIds.contains(messageId)) {
            setLiveMessageUploadProgressLocked(chatId, messageId, null)
            upsertLocalStatusLocked(chatId, messageId, "error")
            emitChangeLocked("chatMessageChanged", chatId, messageId)
            emitChangeLocked("messageStatusChanged", chatId, messageId)
            canceledOutboundMessageIds.remove(messageId)
            return@Thread
          }
          optimisticMessage["encryptedContent"] = encryptedContent
          optimisticRow["message"] = optimisticMessage
          upsertLiveMessageRowLocked(chatId, messageId, optimisticRow)
          pendingOutboundDraftsByMessageId[messageId] = LinkedHashMap(effectivePayload)
          Log.i(
            "ChatEngine",
            "sendMessage prePush chatId=$chatId messageId=$messageId type=$type ${transportDebugStateLocked(chatId)}",
          )

          val client = phoenixClient
          if (client == null) {
            Log.w(
              "ChatEngine",
              "sendMessage queued reason=no_native_socket chatId=$chatId messageId=$messageId ${transportDebugStateLocked(chatId)}",
            )
            upsertLocalStatusLocked(chatId, messageId, "pending")
            queueOutboundDraftLocked(chatId, messageId, effectivePayload, "no_native_socket")
            emitChangeLocked("messageStatusChanged", chatId, messageId)
            ensureNativeTransportAsync("send_no_socket")
            return@Thread
          }
          if (!nativeJoinedChatIds.contains(chatId)) {
            Log.w(
              "ChatEngine",
              "sendMessage queued reason=chat_not_joined chatId=$chatId messageId=$messageId ${transportDebugStateLocked(chatId)}",
            )
            joinNativeChatTopicIfNeededLocked(chatId)
            upsertLocalStatusLocked(chatId, messageId, "pending")
            queueOutboundDraftLocked(chatId, messageId, effectivePayload, "chat_not_joined")
            emitChangeLocked("messageStatusChanged", chatId, messageId)
            ensureNativeTransportAsync("send_chat_not_joined")
            return@Thread
          }

          val ref = client.push(chatTopic(chatId), "message", wirePayload)
          nativePendingMessagePushRefs[ref] = chatId to messageId
          
          Handler(Looper.getMainLooper()).postDelayed({
            synchronized(lock) {
              val pending = nativePendingMessagePushRefs.remove(ref)
              if (pending != null) {
                appendJournalLocked("native-send-timeout", mapOf("chatId" to pending.first, "messageId" to pending.second, "ref" to ref))
                upsertLocalStatusLocked(pending.first, pending.second, "error")
                emitChangeLocked("messageStatusChanged", pending.first, pending.second)
              }
            }
          }, 15000L)
          
          val totalSendMs = System.currentTimeMillis() - optimisticStartMs
          appendJournalLocked("native-send-message", mapOf("chatId" to chatId, "messageId" to messageId, "ref" to ref))
          Log.i("ChatEngine", "sendMessage pushed chatId=$chatId messageId=$messageId ref=$ref encryptMs=${System.currentTimeMillis() - encryptStartMs} totalMs=$totalSendMs")
          emitChangeLocked("messageStatusChanged", chatId, messageId)
        }
      } catch (e: Throwable) { android.util.Log.e("ChatEngine", "CRASH in sendMessage thread:\n" + android.util.Log.getStackTraceString(e)) }
      }.start()

      mapOf(
        "accepted" to true, 
        "queued" to true, 
        "messageId" to messageId, 
        "state" to "sending"
      )
    }
  }

  fun upsertLocalMessageStatus(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]) ?: return getStatus()
    val messageId = normalized(payload["messageId"] ?: payload["message_id"]) ?: return getStatus()
    val status = normalized(payload["status"])?.lowercase() ?: return getStatus()
    return if (status == "delivered" || status == "read") {
      markReceipt(payload, status, "upsert-local-status")
    } else {
      synchronized(lock) {
        upsertLocalStatusLocked(chatId, messageId, status)
        appendJournalLocked("upsert-local-status", payload)
        state["updatedAt"] = System.currentTimeMillis()
        val result = statusSnapshotLocked()
        emitChangeLocked("messageStatusChanged", chatId, messageId)
        result
      }
    }
  }

  fun sendEncryptedMessage(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]) ?: return mapOf("accepted" to false, "reason" to "invalid_chat")
    val messageId = normalized(payload["messageId"] ?: payload["message_id"]) ?: return mapOf("accepted" to false, "reason" to "invalid_message")
    val messagePayload = payload["message"] as? Map<String, Any?> ?: return mapOf("accepted" to false, "reason" to "invalid_payload")
    return synchronized(lock) {
      val client = phoenixClient
      if (client == null) {
        return@synchronized mapOf("accepted" to false, "reason" to "no_native_socket")
      }
      if (!nativeJoinedChatIds.contains(chatId)) {
        joinNativeChatTopicIfNeededLocked(chatId)
        return@synchronized mapOf("accepted" to false, "reason" to "chat_not_joined")
      }
      upsertLocalStatusLocked(chatId, messageId, "sending")
      val ref = client.push(chatTopic(chatId), "message", messagePayload)
      nativePendingMessagePushRefs[ref] = chatId to messageId
      
      Handler(Looper.getMainLooper()).postDelayed({
        synchronized(lock) {
          val pending = nativePendingMessagePushRefs.remove(ref)
          if (pending != null) {
            appendJournalLocked("native-send-timeout", mapOf("chatId" to pending.first, "messageId" to pending.second, "ref" to ref))
            upsertLocalStatusLocked(pending.first, pending.second, "error")
            emitChangeLocked("messageStatusChanged", pending.first, pending.second)
          }
        }
      }, 15000L)
      
      appendJournalLocked("native-send-message", mapOf("chatId" to chatId, "messageId" to messageId, "ref" to ref))
      emitChangeLocked("messageStatusChanged", chatId, messageId)
      mapOf("accepted" to true, "transport" to "native", "ref" to ref)
    }
  }

  fun sendEditMessage(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_chat")
    val messageId = normalized(payload["messageId"] ?: payload["message_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_message")
    val encryptedContent = normalized(payload["encryptedContent"] ?: payload["encrypted_content"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_payload")
    if (synchronized(lock) { isBridgeTextModeLocked() }) {
      return mapOf("accepted" to false, "reason" to "edit_disabled_in_blackout")
    }
    val editedAt = payload["editedAt"] ?: payload["edited_at"]
    return synchronized(lock) {
      val client = phoenixClient
      if (client == null) {
        return@synchronized mapOf("accepted" to false, "reason" to "no_native_socket")
      }
      if (!nativeJoinedChatIds.contains(chatId)) {
        joinNativeChatTopicIfNeededLocked(chatId)
        return@synchronized mapOf("accepted" to false, "reason" to "chat_not_joined")
      }
      val wirePayload = linkedMapOf<String, Any?>(
        "messageId" to messageId,
        "encryptedContent" to encryptedContent,
      )
      if (editedAt != null) wirePayload["editedAt"] = editedAt
      val ref = client.push(chatTopic(chatId), "edit-message", wirePayload)
      nativePendingEditPushRefs[ref] = chatId to messageId
      appendJournalLocked(
        "native-send-edit-message",
        mapOf("chatId" to chatId, "messageId" to messageId, "ref" to ref),
      )
      mapOf("accepted" to true, "transport" to "native", "ref" to ref)
    }
  }

  fun sendDeleteMessage(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_chat")
    val messageId = normalized(payload["messageId"] ?: payload["message_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_message")
    val forEveryone = when (val raw = payload["forEveryone"] ?: payload["for_everyone"]) {
      is Boolean -> raw
      is Number -> raw.toInt() != 0
      is String -> raw.equals("true", ignoreCase = true) || raw == "1" || raw.equals("yes", ignoreCase = true)
      else -> true
    }
    if (synchronized(lock) { isBridgeTextModeLocked() }) {
      return mapOf("accepted" to false, "reason" to "delete_disabled_in_blackout")
    }
    return synchronized(lock) {
      val client = phoenixClient
      if (client == null) {
        return@synchronized mapOf("accepted" to false, "reason" to "no_native_socket")
      }
      if (!nativeJoinedChatIds.contains(chatId)) {
        joinNativeChatTopicIfNeededLocked(chatId)
        return@synchronized mapOf("accepted" to false, "reason" to "chat_not_joined")
      }
      val ref = client.push(
        chatTopic(chatId),
        "delete-message",
        mapOf("messageId" to messageId, "forEveryone" to forEveryone),
      )
      nativePendingDeletePushRefs[ref] = chatId to messageId
      appendJournalLocked(
        "native-send-delete-message",
        mapOf("chatId" to chatId, "messageId" to messageId, "forEveryone" to forEveryone, "ref" to ref),
      )
      mapOf("accepted" to true, "transport" to "native", "ref" to ref)
    }
  }

  fun editMessage(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_chat")
    val messageId = normalized(payload["messageId"] ?: payload["message_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_message")
    val nextText = normalized(payload["text"])?.trim()
      ?: return mapOf("accepted" to false, "reason" to "invalid_payload")
    if (nextText.isEmpty()) return mapOf("accepted" to false, "reason" to "empty_text")

    return synchronized(lock) {
      val existingMessage = findMessagePayloadLocked(chatId, messageId)
        ?: return@synchronized mapOf("accepted" to false, "reason" to "message_not_found")
      val peerUserId = normalizedUpper(payload["peerUserId"] ?: payload["peer_user_id"]) ?: chatPeerUserIdsByChatId[chatId]
      val friendPublicKey = resolveFriendPublicKeyLocked(chatId, peerUserId)
        ?: return@synchronized mapOf("accepted" to false, "reason" to "missing_friend_key")

      val editedAt = System.currentTimeMillis()
      val fullPayload = linkedMapOf<String, Any?>(
        "text" to nextText,
        "isEdited" to true,
        "editedAt" to editedAt,
      )
      normalized(existingMessage["mediaUrl"])?.let { fullPayload["mediaUrl"] = it }
      normalized(existingMessage["fileName"])?.let { fullPayload["fileName"] = it }
      parseDoubleValue(existingMessage["duration"])?.let { fullPayload["duration"] = it }
      normalized(existingMessage["replyToId"])?.let { fullPayload["replyToId"] = it }
      ((existingMessage["metadata"] as? Map<*, *>) ?: emptyMap<Any?, Any?>()).let { metadata ->
        metadata["width"]?.let { fullPayload["width"] = it }
        metadata["height"]?.let { fullPayload["height"] = it }
        metadata["thumbnailBase64"]?.let { fullPayload["thumbnailBase64"] = it }
        metadata["isVideoNote"]?.let { fullPayload["isVideoNote"] = it }
        metadata["waveform"]?.let { fullPayload["waveform"] = it }
      }

      val payloadString = try {
        JSONObject(fullPayload).toString()
      } catch (_: Throwable) {
        return@synchronized mapOf("accepted" to false, "reason" to "payload_encode_failed")
      }
      val myPublicKeyPem = normalized(getConfigValueLocked("publicKeyPem") ?: getConfigValueLocked("publicKey"))
      val encryptedContent = try {
        chatEngineEncryptHybridMessage(friendPublicKey, payloadString, myPublicKeyPem)
      } catch (e: Throwable) {
        appendJournalLocked(
          "native-edit-message-error",
          mapOf("chatId" to chatId, "messageId" to messageId, "reason" to "encrypt_failed", "error" to (e.message ?: "encrypt_failed")),
        )
        return@synchronized mapOf("accepted" to false, "reason" to "encrypt_failed")
      }

      val client = phoenixClient
        ?: return@synchronized mapOf("accepted" to false, "reason" to "no_native_socket")
      if (!nativeJoinedChatIds.contains(chatId)) {
        joinNativeChatTopicIfNeededLocked(chatId)
        return@synchronized mapOf("accepted" to false, "reason" to "chat_not_joined")
      }
      val ref = client.push(
        chatTopic(chatId),
        "edit-message",
        linkedMapOf<String, Any?>(
          "messageId" to messageId,
          "encryptedContent" to encryptedContent,
          "editedAt" to editedAt,
        ),
      )
      nativePendingEditPushRefs[ref] = chatId to messageId
      appendJournalLocked("native-send-edit-message", mapOf("chatId" to chatId, "messageId" to messageId, "ref" to ref))
      applyNativeChatMutationEventLocked(
        chatId,
        "message-edited",
        mapOf("messageId" to messageId, "encryptedContent" to encryptedContent, "editedAt" to editedAt),
      )
      emitChangeLocked("chatMessageEdited", chatId, messageId)
      mapOf("accepted" to true, "transport" to "native", "ref" to ref)
    }
  }

  fun deleteMessage(payload: Map<String, Any?>): Map<String, Any?> =
    sendDeleteMessage(payload)

  fun setChatMuted(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_chat")
    val muted = parseBooleanValue(payload["muted"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_muted")

    val preflight = synchronized(lock) {
      val apiBaseUrl = apiBaseUrlLocked()
      val userId = normalized(payload["userId"] ?: payload["user_id"] ?: getConfigValueLocked("userId"))
      if (apiBaseUrl.isNullOrBlank() || userId.isNullOrBlank()) {
        null
      } else {
        val token = authHeaderTokenLocked()
        appendJournalLocked(
          "native-chat-mute-request",
          mapOf("chatId" to chatId, "muted" to muted, "userId" to userId),
        )
        state["updatedAt"] = System.currentTimeMillis()
        Triple(apiBaseUrl, token, userId)
      }
    } ?: return mapOf("accepted" to false, "reason" to "missing_config", "chatId" to chatId)

    val body =
      JSONObject(mapOf("userId" to preflight.third, "muted" to muted)).toString().toRequestBody(
        "application/json".toMediaTypeOrNull(),
      )
    val requestBuilder = Request.Builder()
      .url("${preflight.first}/api/chat/$chatId/mute")
      .post(body)
      .header("Accept", "application/json")
      .header("Content-Type", "application/json")
      .header("ngrok-skip-browser-warning", "true")
    preflight.second?.takeIf { it.isNotBlank() }?.let {
      requestBuilder.header("Authorization", "Bearer $it")
    }
    historyHttpClient.newCall(requestBuilder.build()).enqueue(object : Callback {
      override fun onFailure(call: Call, e: IOException) {
        synchronized(lock) {
          appendJournalLocked(
            "native-chat-mute-error",
            mapOf("chatId" to chatId, "muted" to muted, "error" to (e.message ?: "network_error")),
          )
        }
      }

      override fun onResponse(call: Call, response: Response) {
        response.use { res ->
          synchronized(lock) {
            if (res.isSuccessful) {
              appendJournalLocked(
                "native-chat-mute-ok",
                mapOf("chatId" to chatId, "muted" to muted, "status" to res.code),
              )
              emitChangeLocked("chatMuteChanged", chatId, null)
            } else {
              appendJournalLocked(
                "native-chat-mute-error",
                mapOf("chatId" to chatId, "muted" to muted, "status" to res.code),
              )
            }
          }
        }
      }
    })

    return mapOf("accepted" to true, "queued" to true, "chatId" to chatId, "muted" to muted)
  }

  fun clearChat(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_chat")

    val preflight = synchronized(lock) {
      val apiBaseUrl = apiBaseUrlLocked()
      if (apiBaseUrl.isNullOrBlank()) {
        null
      } else {
        val token = authHeaderTokenLocked()

        historyRowsByChat.remove(chatId)
        historyLoadingChats.remove(chatId)
        liveMessageRowsByChat.remove(chatId)
        deletedMessageIdsByChat.remove(chatId)
        receiptIndex.remove(chatId)
        localStatusIndex.remove(chatId)
        pendingOutboundQueueByChat.remove(chatId)
        nativeTypingStateByChatId.remove(chatId)
        peerTypingUserIdsByChatId.remove(chatId)
        nativeRecordingStateByChatId.remove(chatId)
        pinnedMessagesByChatId.remove(chatId)
        pinnedFetchInFlightChatIds.remove(chatId)
        chatPeerUserIdsByChatId.remove(chatId)
        openChatChannels.remove(chatId)

        val draftIdsToRemove = pendingOutboundDraftsByMessageId
          .filterValues { draft ->
            normalized(draft["chatId"] ?: draft["chat_id"]) == chatId
          }
          .keys
          .toList()
        draftIdsToRemove.forEach { pendingOutboundDraftsByMessageId.remove(it) }

        if (nativeJoinedChatIds.remove(chatId)) {
          phoenixClient?.leave(chatTopic(chatId))
        }

        appendJournalLocked("native-chat-clear-local", mapOf("chatId" to chatId))
        state["updatedAt"] = System.currentTimeMillis()
        emitChangeLocked("chatRowsReloaded", chatId, null)
        emitChangeLocked("chatCleared", chatId, null)
        Pair(apiBaseUrl, token)
      }
    } ?: return mapOf("accepted" to false, "reason" to "missing_config", "chatId" to chatId)

    val requestBuilder = Request.Builder()
      .url("${preflight.first}/api/chats/$chatId")
      .delete()
      .header("Accept", "application/json")
      .header("ngrok-skip-browser-warning", "true")
    preflight.second?.takeIf { it.isNotBlank() }?.let {
      requestBuilder.header("Authorization", "Bearer $it")
    }
    historyHttpClient.newCall(requestBuilder.build()).enqueue(object : Callback {
      override fun onFailure(call: Call, e: IOException) {
        synchronized(lock) {
          appendJournalLocked(
            "native-chat-clear-error",
            mapOf("chatId" to chatId, "error" to (e.message ?: "network_error")),
          )
        }
      }

      override fun onResponse(call: Call, response: Response) {
        response.use { res ->
          synchronized(lock) {
            if (res.isSuccessful) {
              appendJournalLocked(
                "native-chat-clear-ok",
                mapOf("chatId" to chatId, "status" to res.code),
              )
            } else {
              appendJournalLocked(
                "native-chat-clear-error",
                mapOf("chatId" to chatId, "status" to res.code),
              )
            }
          }
        }
      }
    })

    return mapOf("accepted" to true, "queued" to true, "chatId" to chatId)
  }

  fun blockUser(payload: Map<String, Any?>): Map<String, Any?> {
    val blockedUserId =
      normalized(payload["blockedUserId"] ?: payload["blocked_user_id"] ?: payload["peerUserId"] ?: payload["peer_user_id"])
        ?: return mapOf("accepted" to false, "reason" to "invalid_user")

    val preflight = synchronized(lock) {
      val apiBaseUrl = apiBaseUrlLocked()
      if (apiBaseUrl.isNullOrBlank()) {
        null
      } else {
        val token = authHeaderTokenLocked()
        appendJournalLocked(
          "native-user-block-request",
          mapOf("blockedUserId" to blockedUserId),
        )
        state["updatedAt"] = System.currentTimeMillis()
        Pair(apiBaseUrl, token)
      }
    } ?: return mapOf("accepted" to false, "reason" to "missing_config")

    val body =
      JSONObject(mapOf("blocked_user_id" to blockedUserId)).toString().toRequestBody(
        "application/json".toMediaTypeOrNull(),
      )
    val requestBuilder = Request.Builder()
      .url("${preflight.first}/api/user/block")
      .post(body)
      .header("Accept", "application/json")
      .header("Content-Type", "application/json")
      .header("ngrok-skip-browser-warning", "true")
    preflight.second?.takeIf { it.isNotBlank() }?.let {
      requestBuilder.header("Authorization", "Bearer $it")
    }
    historyHttpClient.newCall(requestBuilder.build()).enqueue(object : Callback {
      override fun onFailure(call: Call, e: IOException) {
        synchronized(lock) {
          appendJournalLocked(
            "native-user-block-error",
            mapOf("blockedUserId" to blockedUserId, "error" to (e.message ?: "network_error")),
          )
        }
      }

      override fun onResponse(call: Call, response: Response) {
        response.use { res ->
          synchronized(lock) {
            if (res.isSuccessful) {
              appendJournalLocked(
                "native-user-block-ok",
                mapOf("blockedUserId" to blockedUserId, "status" to res.code),
              )
              emitChangeLocked("userBlocked", null, null)
            } else {
              appendJournalLocked(
                "native-user-block-error",
                mapOf("blockedUserId" to blockedUserId, "status" to res.code),
              )
            }
          }
        }
      }
    })

    return mapOf("accepted" to true, "queued" to true, "blockedUserId" to blockedUserId)
  }

  private fun parseSavedMessagesResponse(body: String): List<Map<String, Any?>> {
    val trimmed = body.trim()
    if (trimmed.isEmpty()) return emptyList()
    return try {
      if (trimmed.startsWith("[")) {
        jsonArrayToList(JSONArray(trimmed)).mapNotNull { it as? Map<String, Any?> }
      } else {
        val root = JSONObject(trimmed)
        when (val value = root.opt("data") ?: root.opt("messages")) {
          is JSONArray -> jsonArrayToList(value).mapNotNull { it as? Map<String, Any?> }
          is JSONObject -> listOf(jsonObjectToMap(value))
          else -> emptyList()
        }
      }
    } catch (_: Throwable) {
      emptyList()
    }
  }

  private fun normalizeSavedMessagesLocked(rawItems: List<Map<String, Any?>>): List<Map<String, Any?>> {
    val privateKey = decryptPrivateKeyLocked()
    val currentUserId = currentUserIdLocked()
    val rawConfigUserId = normalized(getConfigValueLocked("userId"))

    return rawItems.mapNotNull { raw ->
      val messageId =
        normalized(raw["original_message_id"] ?: raw["messageId"] ?: raw["message_id"] ?: raw["id"])
          ?: return@mapNotNull null
      val fromId = normalized(raw["from_id"] ?: raw["fromId"]) ?: rawConfigUserId
      val type = normalized(raw["type"])?.lowercase(Locale.ROOT) ?: "text"
      val timestampMs =
        parseLongValue(raw["timestamp"] ?: raw["timestampMs"] ?: raw["timestamp_ms"])
          ?: System.currentTimeMillis()
      val encryptedContent = normalized(raw["encrypted_content"] ?: raw["encryptedContent"])
      val parsedExtra = parseJsonToMap(normalized(raw["extra"]).orEmpty())
      val decryptedFields = LinkedHashMap<String, Any?>(parsedExtra)

      val plaintextFallback = normalized(raw["content"] ?: raw["plaintext"] ?: raw["text"]).orEmpty()
      if (plaintextFallback.isNotBlank()) {
        decryptedFields["text"] = plaintextFallback
      }

      if (!encryptedContent.isNullOrBlank()) {
        val isMe = normalizedUpper(fromId) != null && normalizedUpper(fromId) == currentUserId
        val parsedEncryptedFields =
          if (!isLikelyHybridCiphertext(encryptedContent)) {
            parseDecryptedMessagePayload(encryptedContent)
          } else {
            val decrypted = privateKey?.let { chatEngineDecryptHybridMessage(it, encryptedContent, isMe) }.orEmpty()
            if (decrypted.isBlank()) emptyMap() else parseDecryptedMessagePayload(decrypted)
          }
        parsedEncryptedFields.forEach { (key, value) ->
          if (!decryptedFields.containsKey(key)) {
            decryptedFields[key] = value
          }
        }
      }

      val normalizedMessage = linkedMapOf<String, Any?>(
        "id" to messageId,
        "chatId" to "saved_messages",
        "timestamp" to timestampMs,
        "timestampMs" to timestampMs,
        "type" to type,
        "extra" to parsedExtra,
      )
      if (!fromId.isNullOrBlank()) normalizedMessage["fromId"] = fromId
      if (!encryptedContent.isNullOrBlank()) normalizedMessage["encryptedContent"] = encryptedContent

      val resolvedText = normalized(decryptedFields["text"]) ?: plaintextFallback
      if (resolvedText.isNotBlank()) {
        normalizedMessage["plaintext"] = resolvedText
        normalizedMessage["text"] = resolvedText
      }

      normalized(decryptedFields["mediaUrl"] ?: raw["media_url"] ?: raw["mediaUrl"])?.let {
        normalizedMessage["mediaUrl"] = it
      }
      normalized(decryptedFields["fileName"] ?: raw["file_name"] ?: raw["fileName"])?.let {
        normalizedMessage["fileName"] = it
      }
      normalized(decryptedFields["mediaKey"])?.let { normalizedMessage["mediaKey"] = it }
      parseDoubleValue(decryptedFields["latitude"])?.let { normalizedMessage["latitude"] = it }
      parseDoubleValue(decryptedFields["longitude"])?.let { normalizedMessage["longitude"] = it }
      parseDoubleValue(decryptedFields["duration"])?.let { normalizedMessage["duration"] = it }
      parseLongValue(decryptedFields["editedAt"] ?: raw["editedAt"] ?: raw["edited_at"])?.let {
        normalizedMessage["editedAt"] = it
      }
      normalized(raw["status"])?.lowercase(Locale.ROOT)?.let { normalizedMessage["status"] = it }
        ?: run {
          if (normalizedUpper(fromId) == currentUserId) {
            normalizedMessage["status"] = "sent"
          }
        }
      (raw["isEdited"] as? Boolean)?.let { normalizedMessage["isEdited"] = it }
      normalized(decryptedFields["replyToId"])?.let { normalizedMessage["replyToId"] = it }
      decryptedFields["width"]?.let { normalizedMessage["width"] = it }
      decryptedFields["height"]?.let { normalizedMessage["height"] = it }
      decryptedFields["waveform"]?.let { normalizedMessage["waveform"] = it }
      decryptedFields["isVideoNote"]?.let { normalizedMessage["isVideoNote"] = it }
      decryptedFields["contact"]?.let { normalizedMessage["contact"] = it }
      normalized(decryptedFields["stickerId"])?.let { normalizedMessage["stickerId"] = it }
      normalized(decryptedFields["stickerPackId"] ?: decryptedFields["packId"])?.let {
        normalizedMessage["stickerPackId"] = it
        normalizedMessage["packId"] = it
      }
      normalized(
        decryptedFields["stickerBundleFileName"] ?: decryptedFields["bundleFileName"],
      )?.let {
        normalizedMessage["stickerBundleFileName"] = it
        normalizedMessage["bundleFileName"] = it
      }
      normalized(decryptedFields["emoji"])?.let { normalizedMessage["emoji"] = it }
      normalizedMessage
    }
  }

  fun fetchSavedMessages(payload: Map<String, Any?>): Map<String, Any?> {
    val preflight = synchronized(lock) {
      val apiBaseUrl = apiBaseUrlLocked()
      if (apiBaseUrl.isNullOrBlank()) {
        null
      } else {
        Pair(apiBaseUrl, authHeaderTokenLocked())
      }
    } ?: return mapOf("success" to false, "reason" to "missing_config", "messages" to emptyList<Map<String, Any?>>())

    val userId =
      normalized(payload["userId"] ?: payload["user_id"])
        ?: synchronized(lock) { normalized(getConfigValueLocked("userId")) }
        ?: return mapOf("success" to false, "reason" to "missing_user_id", "messages" to emptyList<Map<String, Any?>>())

    val requestBuilder = Request.Builder()
      .url("${preflight.first}/api/saved_messages/${Uri.encode(userId)}")
      .get()
      .header("Accept", "application/json")
      .header("ngrok-skip-browser-warning", "true")
    preflight.second?.takeIf { it.isNotBlank() }?.let {
      requestBuilder.header("Authorization", "Bearer $it")
    }

    return try {
      historyHttpClient.newCall(requestBuilder.build()).execute().use { res ->
        val body = res.body?.string().orEmpty()
        if (!res.isSuccessful) {
          mapOf("success" to false, "status" to res.code, "reason" to "http_${res.code}", "messages" to emptyList<Map<String, Any?>>())
        } else {
          val rawItems = synchronized(lock) { parseSavedMessagesResponse(body) }
          val messages = synchronized(lock) { normalizeSavedMessagesLocked(rawItems) }
          mapOf("success" to true, "messages" to messages)
        }
      }
    } catch (error: Throwable) {
      mapOf(
        "success" to false,
        "reason" to "network_error",
        "error" to (error.message ?: "unknown"),
        "messages" to emptyList<Map<String, Any?>>(),
      )
    }
  }

  fun sendSavedMessage(payload: Map<String, Any?>): Map<String, Any?> {
    val preflight = synchronized(lock) {
      val apiBaseUrl = apiBaseUrlLocked()
      val userId = normalized(getConfigValueLocked("userId"))
      val publicKeyPem = normalized(getConfigValueLocked("publicKeyPem") ?: getConfigValueLocked("publicKey"))
      if (apiBaseUrl.isNullOrBlank() || userId.isNullOrBlank()) {
        null
      } else {
        Triple(apiBaseUrl, authHeaderTokenLocked().orEmpty(), userId) to publicKeyPem
      }
    } ?: return mapOf("success" to false, "reason" to "missing_config")

    val (requestContext, myPublicKeyPem) = preflight
    val apiBaseUrl = requestContext.first
    val token = requestContext.second
    val userId = requestContext.third

    val type = normalized(payload["type"])?.lowercase(Locale.ROOT) ?: "text"
    val text = normalized(payload["text"]).orEmpty()
    if (type == "text" && text.isBlank()) {
      return mapOf("success" to false, "reason" to "empty_text")
    }

    val metadata = payload["metadata"] as? Map<*, *> ?: emptyMap<String, Any?>()
    val messageId =
      normalized(payload["messageId"] ?: payload["message_id"] ?: payload["id"])
        ?: java.util.UUID.randomUUID().toString().lowercase(Locale.ROOT)
    var mediaUrl =
      normalized(metadata["mediaUrl"] ?: metadata["media_url"] ?: payload["mediaUrl"] ?: payload["media_url"])
    var fileName =
      normalized(metadata["fileName"] ?: metadata["file_name"] ?: payload["fileName"])
    var fileSize = parseLongValue(metadata["fileSize"] ?: metadata["file_size"] ?: payload["fileSize"])
    val latitude = parseDoubleValue(metadata["latitude"] ?: payload["latitude"])
    val longitude = parseDoubleValue(metadata["longitude"] ?: payload["longitude"])
    val duration = parseDoubleValue(metadata["duration"] ?: payload["duration"])
    val width = parseLongValue(metadata["width"] ?: payload["width"])
    val height = parseLongValue(metadata["height"] ?: payload["height"])
    var mediaKey = normalized(metadata["mediaKey"] ?: metadata["media_key"] ?: payload["mediaKey"])
    val replyToId = normalized(metadata["replyToId"] ?: metadata["reply_to_id"] ?: payload["replyToId"])
    val contact = metadata["contact"] ?: payload["contact"]
    val isVideoNote = metadata["isVideoNote"] ?: payload["isVideoNote"]
    val waveform = metadata["waveform"] ?: payload["waveform"]
    val stickerId = normalized(metadata["stickerId"] ?: payload["stickerId"])
    val stickerPackId = normalized(
      metadata["stickerPackId"] ?: metadata["packId"] ?: payload["stickerPackId"] ?: payload["packId"],
    )
    val stickerBundleFileName = normalized(
      metadata["stickerBundleFileName"] ?: metadata["bundleFileName"]
        ?: payload["stickerBundleFileName"] ?: payload["bundleFileName"],
    )
    val stickerEmoji = normalized(metadata["emoji"] ?: payload["emoji"])

    val uploadableTypes = setOf("image", "voice", "video", "file", "sticker", "music")
    val currentMediaUrl = mediaUrl
    if (!currentMediaUrl.isNullOrBlank() && uploadableTypes.contains(type) && isLocalMediaUri(currentMediaUrl)) {
      val uploadOutcome = uploadLocalMediaLocked(
        localUri = currentMediaUrl,
        messageType = type,
        fileNameHint = fileName,
        userId = userId,
        token = token,
        apiBaseUrl = apiBaseUrl,
      )
      when (uploadOutcome) {
        is LocalMediaUploadOutcome.Failure -> {
          return mapOf(
            "success" to false,
            "reason" to uploadOutcome.reason,
            "messageId" to messageId,
          )
        }
        is LocalMediaUploadOutcome.Success -> {
          mediaUrl = uploadOutcome.value.remoteUrl
          if (fileName.isNullOrBlank()) fileName = uploadOutcome.value.fileName
          if (fileSize == null) fileSize = uploadOutcome.value.fileSize
          if (mediaKey.isNullOrBlank()) mediaKey = uploadOutcome.value.mediaKey
        }
      }
    }

    var encryptedContent = ""
    if (!myPublicKeyPem.isNullOrBlank()) {
      val encryptedPayload = linkedMapOf<String, Any?>("text" to text)
      if (!mediaUrl.isNullOrBlank()) encryptedPayload["mediaUrl"] = mediaUrl
      if (!mediaKey.isNullOrBlank()) encryptedPayload["mediaKey"] = mediaKey
      if (!fileName.isNullOrBlank()) encryptedPayload["fileName"] = fileName
      if (fileSize != null) encryptedPayload["fileSize"] = fileSize
      if (latitude != null) encryptedPayload["latitude"] = latitude
      if (longitude != null) encryptedPayload["longitude"] = longitude
      if (width != null) encryptedPayload["width"] = width
      if (height != null) encryptedPayload["height"] = height
      if (duration != null) encryptedPayload["duration"] = duration
      if (waveform != null) encryptedPayload["waveform"] = waveform
      if (!replyToId.isNullOrBlank()) encryptedPayload["replyToId"] = replyToId
      if (contact != null) encryptedPayload["contact"] = contact
      if (isVideoNote != null) encryptedPayload["isVideoNote"] = isVideoNote
      if (!stickerId.isNullOrBlank()) encryptedPayload["stickerId"] = stickerId
      if (!stickerPackId.isNullOrBlank()) encryptedPayload["stickerPackId"] = stickerPackId
      if (!stickerBundleFileName.isNullOrBlank()) {
        encryptedPayload["stickerBundleFileName"] = stickerBundleFileName
      }
      if (!stickerEmoji.isNullOrBlank()) encryptedPayload["emoji"] = stickerEmoji
      encryptedContent = try {
        chatEngineEncryptHybridMessage(
          recipientPublicKeyPem = myPublicKeyPem,
          message = JSONObject(encryptedPayload).toString(),
          myPublicKeyPem = myPublicKeyPem,
        )
      } catch (_: Throwable) {
        ""
      }
    }

    val extraPayload = linkedMapOf<String, Any?>()
    if (!fileName.isNullOrBlank()) extraPayload["fileName"] = fileName
    if (fileSize != null) extraPayload["fileSize"] = fileSize
    if (latitude != null) extraPayload["latitude"] = latitude
    if (longitude != null) extraPayload["longitude"] = longitude
    if (width != null) extraPayload["width"] = width
    if (height != null) extraPayload["height"] = height
    if (duration != null) extraPayload["duration"] = duration
    if (waveform != null) extraPayload["waveform"] = waveform
    if (!replyToId.isNullOrBlank()) extraPayload["replyToId"] = replyToId
    if (isVideoNote != null) extraPayload["isVideoNote"] = isVideoNote
    if (!stickerId.isNullOrBlank()) extraPayload["stickerId"] = stickerId
    if (!stickerPackId.isNullOrBlank()) {
      extraPayload["stickerPackId"] = stickerPackId
      extraPayload["packId"] = stickerPackId
    }
    if (!stickerBundleFileName.isNullOrBlank()) {
      extraPayload["stickerBundleFileName"] = stickerBundleFileName
      extraPayload["bundleFileName"] = stickerBundleFileName
    }
    if (!stickerEmoji.isNullOrBlank()) extraPayload["emoji"] = stickerEmoji

    val requestBody = JSONObject(
      linkedMapOf<String, Any?>(
        "user_id" to userId,
        "original_message_id" to messageId,
        "chat_id" to "saved_messages",
        "from_id" to userId,
        "encrypted_content" to encryptedContent,
        "content" to "",
        "type" to type,
        "media_url" to JSONObject.NULL,
        "timestamp" to System.currentTimeMillis(),
        "extra" to JSONObject(extraPayload).toString(),
      ),
    ).toString().toRequestBody("application/json".toMediaTypeOrNull())

    val requestBuilder = Request.Builder()
      .url("$apiBaseUrl/api/saved_messages")
      .post(requestBody)
      .header("Accept", "application/json")
      .header("Content-Type", "application/json")
      .header("ngrok-skip-browser-warning", "true")
    if (token.isNotBlank()) {
      requestBuilder.header("Authorization", "Bearer $token")
    }

    return try {
      historyHttpClient.newCall(requestBuilder.build()).execute().use { res ->
        mapOf(
          "success" to res.isSuccessful,
          "status" to res.code,
          "messageId" to messageId,
        )
      }
    } catch (error: Throwable) {
      mapOf(
        "success" to false,
        "reason" to "network_error",
        "error" to (error.message ?: "unknown"),
        "messageId" to messageId,
      )
    }
  }

  fun deleteSavedMessage(payload: Map<String, Any?>): Map<String, Any?> {
    val preflight = synchronized(lock) {
      val apiBaseUrl = apiBaseUrlLocked()
      if (apiBaseUrl.isNullOrBlank()) {
        null
      } else {
        Pair(apiBaseUrl, authHeaderTokenLocked())
      }
    } ?: return mapOf("success" to false, "reason" to "missing_config")

    val userId =
      normalized(payload["userId"] ?: payload["user_id"])
        ?: synchronized(lock) { normalized(getConfigValueLocked("userId")) }
        ?: return mapOf("success" to false, "reason" to "missing_user_id")
    val messageId =
      normalized(payload["messageId"] ?: payload["message_id"] ?: payload["id"])
        ?: return mapOf("success" to false, "reason" to "missing_message_id")

    val requestBuilder = Request.Builder()
      .url("${preflight.first}/api/saved_messages/${Uri.encode(userId)}/${Uri.encode(messageId)}")
      .delete()
      .header("Accept", "application/json")
      .header("ngrok-skip-browser-warning", "true")
    preflight.second?.takeIf { it.isNotBlank() }?.let {
      requestBuilder.header("Authorization", "Bearer $it")
    }

    return try {
      historyHttpClient.newCall(requestBuilder.build()).execute().use { res ->
        mapOf("success" to res.isSuccessful, "status" to res.code, "messageId" to messageId)
      }
    } catch (error: Throwable) {
      mapOf(
        "success" to false,
        "reason" to "network_error",
        "error" to (error.message ?: "unknown"),
        "messageId" to messageId,
      )
    }
  }

  // MARK: - Agent Config (Native HTTP)

  fun fetchAgentConfig(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("success" to false, "reason" to "invalid_chat")

    val preflight = synchronized(lock) {
      val apiBaseUrl = apiBaseUrlLocked()
      if (apiBaseUrl.isNullOrBlank()) {
        null
      } else {
        Pair(apiBaseUrl, authHeaderTokenLocked())
      }
    } ?: return mapOf("success" to false, "reason" to "missing_config")

    val requestBuilder = Request.Builder()
      .url("${preflight.first}/api/group/$chatId/agent")
      .get()
      .header("Accept", "application/json")
      .header("ngrok-skip-browser-warning", "true")
    preflight.second?.takeIf { it.isNotBlank() }?.let {
      requestBuilder.header("Authorization", "Bearer $it")
    }

    return try {
      historyHttpClient.newCall(requestBuilder.build()).execute().use { res ->
        val body = res.body?.string().orEmpty()
        if (!res.isSuccessful) {
          mapOf("success" to false, "status" to res.code, "reason" to "http_${res.code}")
        } else {
          val parsed = parseJsonToMap(body)
          mapOf("success" to true, "status" to res.code, "config" to parsed)
        }
      }
    } catch (error: Throwable) {
      mapOf(
        "success" to false,
        "reason" to "network_error",
        "error" to (error.message ?: "unknown"),
      )
    }
  }

  fun saveAgentConfig(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("success" to false, "reason" to "invalid_chat")
    val config = payload["config"] as? Map<*, *>
      ?: return mapOf("success" to false, "reason" to "invalid_config")

    val preflight = synchronized(lock) {
      val apiBaseUrl = apiBaseUrlLocked()
      if (apiBaseUrl.isNullOrBlank()) {
        null
      } else {
        Pair(apiBaseUrl, authHeaderTokenLocked())
      }
    } ?: return mapOf("success" to false, "reason" to "missing_config")

    val hasPersistedId =
      normalized(config["id"])
        ?.trim()
        ?.isNotEmpty() == true
    val initialMethod = if (hasPersistedId) "PUT" else "POST"
    val bodyJson = JSONObject(config).toString().toRequestBody("application/json".toMediaTypeOrNull())

    fun execute(method: String): Pair<Int, Map<String, Any?>> {
      val requestBuilder = Request.Builder()
        .url("${preflight.first}/api/group/$chatId/agent")
        .header("Accept", "application/json")
        .header("Content-Type", "application/json")
        .header("ngrok-skip-browser-warning", "true")
      preflight.second?.takeIf { it.isNotBlank() }?.let {
        requestBuilder.header("Authorization", "Bearer $it")
      }
      when (method) {
        "PUT" -> requestBuilder.put(bodyJson)
        else -> requestBuilder.post(bodyJson)
      }
      historyHttpClient.newCall(requestBuilder.build()).execute().use { res ->
        val responseBody = res.body?.string().orEmpty()
        return Pair(res.code, parseJsonToMap(responseBody))
      }
    }

    return try {
      val (initialStatus, initialPayload) = execute(initialMethod)
      if (initialMethod == "POST" && initialStatus == 409) {
        val (retryStatus, retryPayload) = execute("PUT")
        return mapOf(
          "success" to (retryStatus in 200..299),
          "status" to retryStatus,
          "payload" to retryPayload,
        )
      }

      mapOf(
        "success" to (initialStatus in 200..299),
        "status" to initialStatus,
        "payload" to initialPayload,
      )
    } catch (error: Throwable) {
      mapOf(
        "success" to false,
        "reason" to "network_error",
        "error" to (error.message ?: "unknown"),
      )
    }
  }

  fun deleteAgentConfig(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("success" to false, "reason" to "invalid_chat")

    val preflight = synchronized(lock) {
      val apiBaseUrl = apiBaseUrlLocked()
      if (apiBaseUrl.isNullOrBlank()) {
        null
      } else {
        Pair(apiBaseUrl, authHeaderTokenLocked())
      }
    } ?: return mapOf("success" to false, "reason" to "missing_config")

    val requestBuilder = Request.Builder()
      .url("${preflight.first}/api/group/$chatId/agent")
      .delete()
      .header("Accept", "application/json")
      .header("ngrok-skip-browser-warning", "true")
    preflight.second?.takeIf { it.isNotBlank() }?.let {
      requestBuilder.header("Authorization", "Bearer $it")
    }

    return try {
      historyHttpClient.newCall(requestBuilder.build()).execute().use { res ->
        mapOf("success" to res.isSuccessful, "status" to res.code)
      }
    } catch (error: Throwable) {
      mapOf(
        "success" to false,
        "reason" to "network_error",
        "error" to (error.message ?: "unknown"),
      )
    }
  }

  fun generateAgentPrompt(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("success" to false, "reason" to "invalid_chat")
    val input = normalized(payload["input"] ?: payload["description"] ?: payload["prompt"]).orEmpty().trim()
    if (input.isBlank()) {
      return mapOf("success" to false, "reason" to "empty_input")
    }

    val enabledTools =
      (payload["enabledTools"] as? List<*>
        ?: payload["enabled_tools"] as? List<*>)
        ?.mapNotNull { normalized(it)?.trim()?.takeIf { value -> value.isNotEmpty() } }
        ?: emptyList()

    val preflight = synchronized(lock) {
      val apiBaseUrl = apiBaseUrlLocked()
      if (apiBaseUrl.isNullOrBlank()) {
        null
      } else {
        Pair(apiBaseUrl, authHeaderTokenLocked())
      }
    } ?: return mapOf("success" to false, "reason" to "missing_config")

    val requestBody = JSONObject(
      mapOf(
        "input" to input,
        "enabled_tools" to enabledTools,
      ),
    ).toString().toRequestBody("application/json".toMediaTypeOrNull())

    val requestBuilder = Request.Builder()
      .url("${preflight.first}/api/group/$chatId/agent/generate_prompt")
      .post(requestBody)
      .header("Accept", "application/json")
      .header("Content-Type", "application/json")
      .header("ngrok-skip-browser-warning", "true")
    preflight.second?.takeIf { it.isNotBlank() }?.let {
      requestBuilder.header("Authorization", "Bearer $it")
    }

    return try {
      historyHttpClient.newCall(requestBuilder.build()).execute().use { res ->
        val body = res.body?.string().orEmpty()
        val parsed = parseJsonToMap(body)
        mapOf(
          "success" to res.isSuccessful,
          "status" to res.code,
          "payload" to parsed,
        )
      }
    } catch (error: Throwable) {
      mapOf(
        "success" to false,
        "reason" to "network_error",
        "error" to (error.message ?: "unknown"),
      )
    }
  }

  fun getPinnedMessages(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]).orEmpty()
    val shouldRefresh = parseBooleanValue(payload["refresh"]) == true
    if (chatId.isBlank()) {
      return mapOf("chatId" to "", "loading" to false, "data" to emptyList<Map<String, Any?>>())
    }

    return synchronized(lock) {
      val hasCache = pinnedMessagesByChatId.containsKey(chatId)
      if (!hasCache) {
        pinnedMessagesByChatId[chatId] = mutableListOf()
      }
      if ((shouldRefresh || !hasCache) && !pinnedFetchInFlightChatIds.contains(chatId)) {
        fetchPinnedMessagesLocked(chatId, "on_demand")
      }
      mapOf(
        "chatId" to chatId,
        "loading" to pinnedFetchInFlightChatIds.contains(chatId),
        "data" to pinnedMessagesByChatId[chatId].orEmpty(),
      )
    }
  }

  fun pinMessage(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_chat")
    val messageId = normalized(payload["messageId"] ?: payload["message_id"])
      ?: return mapOf("accepted" to false, "reason" to "invalid_message")
    val pinned = parseBooleanValue(payload["pinned"]) ?: true

    val preflight = synchronized(lock) {
      val apiBaseUrl = apiBaseUrlLocked()
      if (apiBaseUrl.isNullOrBlank()) {
        null
      } else {
        applyPinnedUpdateLocked(
          chatId = chatId,
          messageId = messageId,
          pinned = pinned,
          payload = mapOf(
            "messageId" to messageId,
            "chatId" to chatId,
            "timestamp" to System.currentTimeMillis(),
          ),
          trigger = "local_pin_request",
          refreshRemote = false,
        )
        state["updatedAt"] = System.currentTimeMillis()
        emitChangeLocked("chatPinnedUpdated", chatId, messageId)
        Pair(apiBaseUrl, authHeaderTokenLocked())
      }
    } ?: return mapOf("accepted" to false, "reason" to "missing_config", "chatId" to chatId)

    val body =
      JSONObject(mapOf("pinned" to pinned)).toString().toRequestBody(
        "application/json".toMediaTypeOrNull(),
      )
    val requestBuilder = Request.Builder()
      .url("${preflight.first}/api/chat/$chatId/messages/$messageId/pin")
      .post(body)
      .header("Accept", "application/json")
      .header("Content-Type", "application/json")
      .header("ngrok-skip-browser-warning", "true")
    preflight.second?.takeIf { it.isNotBlank() }?.let {
      requestBuilder.header("Authorization", "Bearer $it")
    }

    historyHttpClient.newCall(requestBuilder.build()).enqueue(object : Callback {
      override fun onFailure(call: Call, e: IOException) {
        synchronized(lock) {
          appendJournalLocked(
            "native-pin-message-error",
            mapOf(
              "chatId" to chatId,
              "messageId" to messageId,
              "pinned" to pinned,
              "error" to (e.message ?: "network_error"),
            ),
          )
          fetchPinnedMessagesLocked(chatId, "pin_error_reconcile")
        }
      }

      override fun onResponse(call: Call, response: Response) {
        response.use { res ->
          synchronized(lock) {
            if (res.isSuccessful) {
              appendJournalLocked(
                "native-pin-message-ok",
                mapOf(
                  "chatId" to chatId,
                  "messageId" to messageId,
                  "pinned" to pinned,
                  "status" to res.code,
                ),
              )
            } else {
              appendJournalLocked(
                "native-pin-message-error",
                mapOf(
                  "chatId" to chatId,
                  "messageId" to messageId,
                  "pinned" to pinned,
                  "status" to res.code,
                ),
              )
            }
            fetchPinnedMessagesLocked(chatId, "pin_request_complete")
          }
        }
      }
    })

    return mapOf(
      "accepted" to true,
      "queued" to true,
      "chatId" to chatId,
      "messageId" to messageId,
      "pinned" to pinned,
    )
  }

  fun getChatProfileSummary(payload: Map<String, Any?>): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]).orEmpty()
    if (chatId.isBlank()) {
      return mapOf(
        "chatId" to "",
        "historyLoaded" to false,
        "totalMessages" to 0,
        "mediaCount" to 0,
        "fileCount" to 0,
        "linkCount" to 0,
        "recentFiles" to emptyList<String>(),
      )
    }
    return synchronized(lock) {
      val rows = mergedChatRowsLocked(chatId)
      var totalMessages = 0
      var mediaCount = 0
      var fileCount = 0
      var linkCount = 0
      val recentFiles = mutableListOf<String>()

      rows.forEach { row ->
        if (normalized(row["kind"]) != "message") return@forEach
        val message = row["message"] as? Map<*, *> ?: return@forEach
        totalMessages += 1

        val type = normalized(message["type"])?.lowercase() ?: "text"
        val text = normalized(message["text"]).orEmpty()
        val caption = normalized(message["caption"]).orEmpty()
        val mediaUrl = normalized(message["mediaUrl"]).orEmpty()
        val fileName = normalized(message["fileName"]).orEmpty()

        val isMediaType = setOf("image", "gif", "video", "voice", "music").contains(type)
        if (isMediaType) mediaCount += 1

        val isFileType = type == "file" || (!isMediaType && fileName.isNotBlank())
        if (isFileType) {
          fileCount += 1
          if (fileName.isNotBlank() && recentFiles.size < 3) {
            recentFiles.add(fileName)
          }
        }

        if (containsLinkCandidate(text) || containsLinkCandidate(caption)) {
          linkCount += 1
        }
      }

      mapOf(
        "chatId" to chatId,
        "historyLoaded" to historyRowsByChat.containsKey(chatId),
        "totalMessages" to totalMessages,
        "mediaCount" to mediaCount,
        "fileCount" to fileCount,
        "linkCount" to linkCount,
        "recentFiles" to recentFiles,
      )
    }
  }

  fun getJournal(): List<Map<String, Any?>> {
    val ctx = appContextRef ?: return emptyList()
    return ChatEngineStore.getJournal(ctx)
  }

  fun clearJournal(): Map<String, Any?> {
    appContextRef?.let { ChatEngineStore.clearJournal(it) }
    synchronized(lock) {
      state["updatedAt"] = System.currentTimeMillis()
      state["journalCount"] = 0
      return statusSnapshotLocked()
    }
  }

  fun getLiveMessageRow(payload: Map<String, Any?>): Map<String, Any?>? {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]) ?: return null
    val messageId = normalized(payload["messageId"] ?: payload["message_id"]) ?: return null
    synchronized(lock) {
      return liveMessageRowsByChat[chatId]?.get(messageId)
    }
  }

  fun getChatRows(payload: Map<String, Any?>): List<Map<String, Any?>> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]) ?: return emptyList()
    synchronized(lock) {
      return mergedChatRowsLocked(chatId)
    }
  }

  fun getLiveMessageRows(payload: Map<String, Any?>): Map<String, Map<String, Any?>> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]) ?: return emptyMap()
    synchronized(lock) {
      return liveMessageRowsByChat[chatId]?.toMap() ?: emptyMap()
    }
  }

  fun isChatHistoryLoaded(payload: Map<String, Any?>): Boolean {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]) ?: return false
    synchronized(lock) {
      return historyRowsByChat.containsKey(chatId)
    }
  }

  fun typingUserIds(chatId: String?): List<String> {
    val normalizedChatId = normalized(chatId) ?: return emptyList()
    synchronized(lock) {
      return peerTypingUserIdsByChatId[normalizedChatId]?.toList()?.sorted() ?: emptyList()
    }
  }

  fun isTyping(payload: Map<String, Any?>): Boolean {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]) ?: return false
    synchronized(lock) {
      return peerTypingUserIdsByChatId[chatId]?.isNotEmpty() == true
    }
  }

  fun isLiveMessageDeleted(payload: Map<String, Any?>): Boolean {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]) ?: return false
    val messageId = normalized(payload["messageId"] ?: payload["message_id"]) ?: return false
    synchronized(lock) {
      return deletedMessageIdsByChat[chatId]?.contains(messageId) == true
    }
  }

  // Shadow-mode bridge until native Phoenix transport is implemented.
  fun setPresenceSnapshot(userIds: List<String>): Map<String, Any?> =
    synchronized(lock) {
      if (nativePresenceActive) {
        state["updatedAt"] = System.currentTimeMillis()
        appendJournalLocked("set-presence-snapshot-ignored", mapOf("count" to userIds.size))
        return statusSnapshotLocked()
      }
      onlineUsers.clear()
      userIds.mapNotNullTo(onlineUsers) { normalizedUpper(it) }
      onlineUsers.forEach { userId -> lastSeenByUserId.remove(userId) }
      state["updatedAt"] = System.currentTimeMillis()
      appendJournalLocked("set-presence-snapshot", mapOf("count" to onlineUsers.size))
      state["presenceSource"] = "shadow"
      val result = statusSnapshotLocked()
      emitChangeLocked("presenceChanged", null, null)
      result
    }

  fun resolveDisplayStatus(
    chatId: String?,
    messageId: String?,
    rawStatus: String?,
    isMe: Boolean,
    peerUserId: String?,
  ): String? {
    val normalizedRaw = rawStatus?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
    if (!isMe) return normalizedRaw
    if (normalizedRaw == "read") return "read"
    synchronized(lock) {
      val receipt = if (!chatId.isNullOrBlank() && !messageId.isNullOrBlank()) {
        receiptIndex[chatId]?.get(messageId)
      } else {
        null
      }
      val localStatus = if (!chatId.isNullOrBlank() && !messageId.isNullOrBlank()) {
        localStatusIndex[chatId]?.get(messageId)
      } else {
        null
      }
      if (receipt == "read") return "read"
      if (receipt == "delivered") return "delivered"
      if (normalizedRaw == "delivered") return "delivered"
      when (localStatus) {
        "error" -> return "error"
        "sent" -> {
          if (!peerUserId.isNullOrBlank() && onlineUsers.contains(peerUserId.trim().uppercase())) {
            return "delivered"
          }
          return "sent"
        }
        "pending", "sending" -> {
          if (normalizedRaw == null || normalizedRaw == "pending" || normalizedRaw == "sending") {
            return localStatus
          }
        }
      }
      if (normalizedRaw == "sent" && !peerUserId.isNullOrBlank() && onlineUsers.contains(peerUserId.trim().uppercase())) {
        return "delivered"
      }
      return normalizedRaw
    }
  }

  private fun markReceipt(payload: Map<String, Any?>, status: String, eventName: String): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]) ?: return getStatus()
    val messageId = normalized(payload["messageId"] ?: payload["message_id"]) ?: return getStatus()
    synchronized(lock) {
      val chatMap = receiptIndex.getOrPut(chatId) { linkedMapOf() }
      chatMap[messageId] = strongerStatus(chatMap[messageId], status)
      upsertLocalStatusLocked(chatId, messageId, status)
      state["updatedAt"] = System.currentTimeMillis()
      appendJournalLocked(eventName, payload)
      val result = statusSnapshotLocked()
      emitChangeLocked("messageStatusChanged", chatId, messageId)
      return result
    }
  }

  private fun sendReceipt(
    payload: Map<String, Any?>,
    status: String,
    eventName: String,
    wireEvent: String,
  ): Map<String, Any?> {
    val chatId = normalized(payload["chatId"] ?: payload["chat_id"]) ?: return getStatus()
    val messageId = normalized(payload["messageId"] ?: payload["message_id"]) ?: return getStatus()
    synchronized(lock) {
      val chatMap = receiptIndex.getOrPut(chatId) { linkedMapOf() }
      chatMap[messageId] = strongerStatus(chatMap[messageId], status)
      upsertLocalStatusLocked(chatId, messageId, status)

      var accepted = false
      var ref: String? = null
      if (nativeJoinedChatIds.contains(chatId) && (state["connected"] as? Boolean) == true) {
        val client = phoenixClient
        if (client != null) {
          ref = client.push(chatTopic(chatId), wireEvent, mapOf("messageId" to messageId))
          accepted = true
          appendJournalLocked(
            "native-$eventName-push",
            mapOf("chatId" to chatId, "messageId" to messageId, "ref" to ref),
          )
        }
      }

      state["updatedAt"] = System.currentTimeMillis()
      appendJournalLocked(eventName, payload)
      val result = LinkedHashMap(statusSnapshotLocked())
      emitChangeLocked("messageStatusChanged", chatId, messageId)
      result["accepted"] = accepted
      result["transport"] = if (accepted) "native" else "shadow"
      if (ref != null) result["ref"] = ref
      return result
    }
  }

  fun setListener(listenerId: String, listener: ((String, String?, String?) -> Unit)?) {
    synchronized(lock) {
      if (listener == null) {
        listeners.remove(listenerId)
      } else {
        listeners[listenerId] = listener
      }
    }
  }

  private fun strongerStatus(current: String?, incoming: String): String {
    fun rank(v: String?): Int = when (v) {
      "read" -> 2
      "delivered" -> 1
      else -> 0
    }
    return if (rank(incoming) >= rank(current)) incoming else (current ?: incoming)
  }

  private fun strongerDisplayStatus(current: String?, incoming: String): String {
    fun rank(v: String?): Int = when (v) {
      "error" -> 6
      "read" -> 5
      "delivered" -> 4
      "sent" -> 3
      "sending" -> 2
      "pending" -> 1
      else -> 0
    }
    return if (rank(incoming) >= rank(current)) incoming else (current ?: incoming)
  }

  private fun upsertLocalStatusLocked(chatId: String, messageId: String, status: String) {
    val chatMap = localStatusIndex.getOrPut(chatId) { linkedMapOf() }
    val nextStatus = strongerDisplayStatus(chatMap[messageId], status)
    chatMap[messageId] = nextStatus
    setLiveMessageStatusLocked(chatId, messageId, nextStatus)
    if (nextStatus == "sent" || nextStatus == "delivered" || nextStatus == "read" || nextStatus == "error") {
      setLiveMessageUploadProgressLocked(chatId, messageId, null)
    }
    state["localStatusCount"] = localStatusIndex.values.sumOf { it.size }
    state["updatedAt"] = System.currentTimeMillis()
  }

  private fun removeMessageIndicesLocked(chatId: String, messageId: String) {
    receiptIndex[chatId]?.let { chatMap ->
      chatMap.remove(messageId)
      if (chatMap.isEmpty()) receiptIndex.remove(chatId)
    }
    localStatusIndex[chatId]?.let { chatMap ->
      chatMap.remove(messageId)
      if (chatMap.isEmpty()) localStatusIndex.remove(chatId)
    }
    state["receiptCount"] = receiptIndex.values.sumOf { it.size }
    state["localStatusCount"] = localStatusIndex.values.sumOf { it.size }
    state["updatedAt"] = System.currentTimeMillis()
  }

  private fun getConfigValueLocked(key: String): Any? {
    val ctx = appContextRef ?: return null
    return ChatEngineStore.getConfig(ctx)[key]
  }

  fun isJsEmergencyFallbackEnabled(): Boolean =
    synchronized(lock) {
      when (val raw = getConfigValueLocked("chatNativeJsFallbackEnabled")) {
        is Boolean -> raw
        is Number -> raw.toInt() != 0
        is String -> raw.trim().lowercase() in setOf("1", "true", "yes", "on")
        else -> false
      }
    }

  private fun extractPublicKeyValue(map: Map<String, Any?>): String? =
    normalized(map["publicKey"] ?: map["friendKey"] ?: map["friendPublicKey"] ?: map["public_key"])

  private fun cacheChatPeerInfoLocked(chatId: String, chat: JSONObject) {
    val friendId = normalizedUpper(chat.opt("friendId") ?: chat.opt("friend_id"))
    if (!friendId.isNullOrBlank()) {
      chatPeerUserIdsByChatId[chatId] = friendId
      val key = normalized(chat.opt("publicKey") ?: chat.opt("friendKey") ?: chat.opt("friendPublicKey") ?: chat.opt("public_key"))
      if (!key.isNullOrBlank()) {
        friendPublicKeysByUserId[friendId] = key
      }
    }
  }

  private fun resolveFriendPublicKeyLocked(chatId: String, peerUserIdHint: String?): String? {
    val peerId = (peerUserIdHint ?: chatPeerUserIdsByChatId[chatId])?.trim()?.uppercase() ?: return null
    friendPublicKeysByUserId[peerId]?.let { return it }
    val isBridgeText = isBridgeTextModeLocked()
    val requestUrl =
      if (isBridgeText) {
        bridgeUrlLocked("/bridge/v1/keys/peer")
      } else {
        apiBaseUrlLocked()?.let { "$it/api/user/$peerId" }
      } ?: return null
    val token = authHeaderTokenLocked() ?: return null
    val requestBuilder = Request.Builder()
      .url(requestUrl)
      .header("Accept", "application/json")
      .header("ngrok-skip-browser-warning", "true")
      .header("Authorization", "Bearer $token")
    if (isBridgeText) {
      requestBuilder
        .post(
          JSONObject(mapOf("peerUserId" to peerId, "chatId" to chatId)).toString().toRequestBody(
            "application/json".toMediaTypeOrNull(),
          ),
        )
        .header("Content-Type", "application/json")
    } else {
      requestBuilder.get()
    }
    val request = requestBuilder.build()
    val response = try {
      historyHttpClient.newCall(request).execute()
    } catch (_: Throwable) {
      return null
    }
    response.use { res ->
      if (!res.isSuccessful) return null
      val body = try { res.body?.string() } catch (_: Throwable) { null } ?: return null
      return try {
        val json = JSONObject(body)
        val map = linkedMapOf<String, Any?>()
        json.keys().forEach { key -> map[key] = json.opt(key) }
        val nested = map["data"] as? Map<String, Any?>
        val key = extractPublicKeyValue(map) ?: nested?.let(::extractPublicKeyValue)
        if (!key.isNullOrBlank()) {
          friendPublicKeysByUserId[peerId] = key
          chatPeerUserIdsByChatId[chatId] = peerId
        }
        key
      } catch (_: Throwable) {
        null
      }
    }
  }

  private fun apiBaseUrlLocked(): String? {
    val explicit = normalized(getConfigValueLocked("apiBaseUrl") ?: getConfigValueLocked("baseUrl"))
    if (!explicit.isNullOrBlank()) return explicit
    val socketUrl = normalized(getConfigValueLocked("socketUrl") ?: getConfigValueLocked("url")) ?: return null
    val parsed = socketUrl.toHttpUrlOrNull() ?: return null
    val scheme = when (parsed.scheme) {
      "wss" -> "https"
      "ws" -> "http"
      else -> parsed.scheme
    }
    val pathSegments = parsed.pathSegments.toMutableList()
    if (pathSegments.isNotEmpty() && pathSegments.last().equals("socket", ignoreCase = true)) {
      pathSegments.removeAt(pathSegments.size - 1)
    }
    val rebuilt = parsed.newBuilder().scheme(scheme).encodedPath("/" + pathSegments.joinToString("/")).build()
    return rebuilt.toString().trimEnd('/')
  }

  private fun authHeaderTokenLocked(): String? =
    normalized(getConfigValueLocked("authToken") ?: getConfigValueLocked("token"))

  private fun currentUserIdLocked(): String? =
    normalizedUpper(getConfigValueLocked("userId"))

  private fun decryptPrivateKeyLocked(): PrivateKey? {
    val pem = normalized(getConfigValueLocked("privateKeyPem") ?: getConfigValueLocked("privateKey")) ?: return null
    // Check TTL: clear cached key if it has expired to limit in-memory exposure.
    val now = System.currentTimeMillis()
    if (cachedDecryptKeyTimestampMs > 0 && (now - cachedDecryptKeyTimestampMs) >= keyTTLMs) {
      cachedDecryptPrivateKey = null
      cachedDecryptPrivateKeyPem = null
      cachedDecryptKeyTimestampMs = 0L
    }
    if (cachedDecryptPrivateKey != null && cachedDecryptPrivateKeyPem == pem) {
      cachedDecryptKeyTimestampMs = now
      return cachedDecryptPrivateKey
    }
    return try {
      val key = chatEngineLoadPrivateKeyFromPem(pem)
      cachedDecryptPrivateKeyPem = pem
      cachedDecryptPrivateKey = key
      cachedDecryptKeyTimestampMs = now
      key
    } catch (_: Throwable) {
      cachedDecryptPrivateKeyPem = pem
      cachedDecryptPrivateKey = null
      cachedDecryptKeyTimestampMs = 0L
      null
    }
  }

  private fun parseLongValue(value: Any?): Long? =
    when (value) {
      is Number -> value.toLong()
      is String -> value.toLongOrNull()
      else -> null
    }

  private fun parseDoubleValue(value: Any?): Double? =
    when (value) {
      is Number -> value.toDouble()
      is String -> value.toDoubleOrNull()
      else -> null
    }

  private fun parseBooleanValue(value: Any?): Boolean? =
    when (value) {
      is Boolean -> value
      is Number -> value.toInt() != 0
      is String -> {
        when (value.trim().lowercase()) {
          "1", "true", "yes", "on" -> true
          "0", "false", "no", "off" -> false
          else -> null
        }
      }
      else -> null
    }

  private fun parseWaveformArray(value: Any?): List<Double>? {
    return parseNormalizedWaveform(value)?.map(Float::toDouble)
  }

  private fun parseDecryptedMessagePayload(raw: String): Map<String, Any?> {
    val trimmed = raw.trim()
    if (!trimmed.startsWith("{")) return mapOf("text" to raw)
    return try {
      val json = JSONObject(trimmed)
      val out = linkedMapOf<String, Any?>()
      if (json.has("text")) out["text"] = json.optString("text", "")
      if (json.has("mediaUrl")) out["mediaUrl"] = json.opt("mediaUrl")
      if (json.has("mediaKey")) out["mediaKey"] = json.opt("mediaKey")
      if (json.has("fileName")) out["fileName"] = json.opt("fileName")
      if (json.has("fileSize")) out["fileSize"] = json.opt("fileSize")
      if (json.has("latitude")) out["latitude"] = json.opt("latitude")
      if (json.has("longitude")) out["longitude"] = json.opt("longitude")
      if (json.has("duration")) out["duration"] = json.opt("duration")
      if (json.has("replyToId")) out["replyToId"] = json.opt("replyToId")
      if (json.has("contact")) out["contact"] = json.opt("contact")
      if (json.has("caption")) out["caption"] = json.opt("caption")
      if (json.has("viewOnce")) out["viewOnce"] = json.opt("viewOnce")
      if (json.has("isEdited")) out["isEdited"] = json.optBoolean("isEdited", false)
      if (json.has("editedAt")) out["editedAt"] = json.opt("editedAt")
      if (json.has("waveform")) out["waveform"] = json.opt("waveform")
      if (json.has("isVideoNote")) out["isVideoNote"] = json.optBoolean("isVideoNote", false)
      if (json.has("width")) out["width"] = json.opt("width")
      if (json.has("height")) out["height"] = json.opt("height")
      if (json.has("thumbnailBase64")) out["thumbnailBase64"] = json.opt("thumbnailBase64")
      if (json.has("stickerId")) out["stickerId"] = json.opt("stickerId")
      if (json.has("stickerPackId") || json.has("packId")) {
        out["stickerPackId"] =
          if (json.has("stickerPackId")) json.opt("stickerPackId") else json.opt("packId")
      }
      if (json.has("stickerBundleFileName") || json.has("bundleFileName")) {
        out["stickerBundleFileName"] =
          if (json.has("stickerBundleFileName")) {
            json.opt("stickerBundleFileName")
          } else {
            json.opt("bundleFileName")
          }
      }
      if (json.has("emoji")) out["emoji"] = json.opt("emoji")
      out
    } catch (_: Throwable) {
      mapOf("text" to raw)
    }
  }

  private fun isLikelyHybridCiphertext(raw: String?): Boolean {
    val trimmed = raw?.trim() ?: return false
    if (!trimmed.startsWith("{")) return false
    return try {
      val json = JSONObject(trimmed)
      json.has("iv") && json.has("c") && json.has("k")
    } catch (_: Throwable) {
      false
    }
  }

  private fun parseJsonToMap(raw: String): Map<String, Any?> {
    val trimmed = raw.trim()
    if (trimmed.isEmpty()) return emptyMap()
    return try {
      jsonObjectToMap(JSONObject(trimmed))
    } catch (_: Throwable) {
      emptyMap()
    }
  }

  private fun jsonObjectToMap(json: JSONObject): Map<String, Any?> {
    val out = linkedMapOf<String, Any?>()
    val iterator = json.keys()
    while (iterator.hasNext()) {
      val key = iterator.next()
      out[key] = jsonValueToKotlin(json.opt(key))
    }
    return out
  }

  private fun jsonArrayToList(array: JSONArray): List<Any?> {
    val out = mutableListOf<Any?>()
    for (index in 0 until array.length()) {
      out.add(jsonValueToKotlin(array.opt(index)))
    }
    return out
  }

  private fun jsonValueToKotlin(value: Any?): Any? {
    return when (value) {
      null, JSONObject.NULL -> null
      is JSONObject -> jsonObjectToMap(value)
      is JSONArray -> jsonArrayToList(value)
      else -> value
    }
  }

  private fun containsLinkCandidate(value: String?): Boolean {
    val normalizedValue = value?.trim()?.lowercase().orEmpty()
    if (normalizedValue.isBlank()) return false
    return normalizedValue.contains("http://")
      || normalizedValue.contains("https://")
      || normalizedValue.contains("www.")
  }

  private fun formatMessageTimeLabel(timestampMs: Long): String {
    val formatter = SimpleDateFormat("HH:mm", Locale.getDefault())
    return formatter.format(Date(timestampMs))
  }

  private fun messageIdFromRow(row: Map<String, Any?>): String? {
    if (normalized(row["kind"]) != "message") return null
    val message = row["message"] as? Map<*, *> ?: return null
    return normalized(message["id"])
  }

  private fun messageTimestampMsFromRow(row: Map<String, Any?>): Long {
    val message = row["message"] as? Map<*, *> ?: return 0L
    return parseLongValue(message["timestampMs"] ?: message["timestamp_ms"] ?: message["timestamp"]) ?: 0L
  }

  private fun mergedChatRowsLocked(chatId: String): List<Map<String, Any?>> {
    val historyRows = historyRowsByChat[chatId].orEmpty()
    val liveRows = liveMessageRowsByChat[chatId].orEmpty()
    val deletedIds = deletedMessageIdsByChat[chatId].orEmpty()
    if (historyRows.isEmpty() && liveRows.isEmpty()) return emptyList()

    val mergedById = linkedMapOf<String, Map<String, Any?>>()
    val rowsWithoutIds = ArrayList<Map<String, Any?>>()
    for (row in historyRows) {
      val messageId = messageIdFromRow(row)
      if (messageId == null) {
        rowsWithoutIds.add(row)
        continue
      }
      if (deletedIds.contains(messageId)) continue
      mergedById[messageId] = liveRows[messageId] ?: row
    }

    for ((messageId, row) in liveRows) {
      if (deletedIds.contains(messageId) || mergedById.containsKey(messageId)) continue
      mergedById[messageId] = row
    }

    val mergedRows = ArrayList<Map<String, Any?>>(mergedById.values)
    mergedRows.sortWith(
      compareBy<Map<String, Any?>> { messageTimestampMsFromRow(it) }
        .thenBy { messageIdFromRow(it).orEmpty() },
    )
    if (rowsWithoutIds.isNotEmpty()) {
      mergedRows.addAll(0, rowsWithoutIds)
    }
    return mergedRows
  }

  private fun mergedStoredHistoryRowsLocked(
    chatId: String,
    remoteRows: List<Map<String, Any?>>,
  ): List<Map<String, Any?>> {
    val existingRows = historyRowsByChat[chatId].orEmpty()
    val deletedIds = deletedMessageIdsByChat[chatId].orEmpty()
    if (existingRows.isEmpty() && remoteRows.isEmpty()) return emptyList()

    val mergedById = linkedMapOf<String, Map<String, Any?>>()
    val rowsWithoutIds = ArrayList<Map<String, Any?>>()
    for (row in existingRows) {
      val messageId = messageIdFromRow(row)
      if (messageId == null) {
        rowsWithoutIds.add(row)
        continue
      }
      if (deletedIds.contains(messageId)) continue
      mergedById[messageId] = row
    }

    for (row in remoteRows) {
      val messageId = messageIdFromRow(row)
      if (messageId == null) {
        rowsWithoutIds.add(row)
        continue
      }
      if (deletedIds.contains(messageId)) continue
      mergedById[messageId] = row
    }

    val mergedRows = ArrayList<Map<String, Any?>>(mergedById.values)
    mergedRows.sortWith(
      compareBy<Map<String, Any?>> { messageTimestampMsFromRow(it) }
        .thenBy { messageIdFromRow(it).orEmpty() },
    )
    if (rowsWithoutIds.isNotEmpty()) {
      mergedRows.addAll(0, rowsWithoutIds)
    }
    return mergedRows
  }

  private fun upsertLiveMessageRowLocked(chatId: String, messageId: String, row: Map<String, Any?>) {
    val perChat = liveMessageRowsByChat.getOrPut(chatId) { linkedMapOf() }
    perChat[messageId] = row
    deletedMessageIdsByChat[chatId]?.remove(messageId)
    if (deletedMessageIdsByChat[chatId]?.isEmpty() == true) {
      deletedMessageIdsByChat.remove(chatId)
    }
  }

  private fun setLiveMessageStatusLocked(chatId: String, messageId: String, status: String) {
    val row = liveMessageRowsByChat[chatId]?.get(messageId) ?: return
    val nextRow = LinkedHashMap(row)
    val msg = (nextRow["message"] as? Map<*, *>)?.let { LinkedHashMap(it) } ?: return
    msg["status"] = status
    nextRow["message"] = msg
    liveMessageRowsByChat[chatId]?.put(messageId, nextRow)
  }

  private fun setLiveMessageUploadProgressLocked(chatId: String, messageId: String, progress: Float?): Boolean {
    val row = liveMessageRowsByChat[chatId]?.get(messageId) ?: return false
    val nextRow = LinkedHashMap(row)
    val msg = (nextRow["message"] as? Map<*, *>)?.let { LinkedHashMap(it) } ?: return false
    val previousProgress =
      when (val existing = msg["uploadProgress"]) {
        is Number -> existing.toFloat().coerceIn(0f, 1f)
        is String -> existing.toFloatOrNull()?.coerceIn(0f, 1f)
        else -> null
      }
    val normalizedProgress =
      if (progress != null && progress.isFinite()) {
        progress.coerceIn(0f, 1f)
      } else {
        null
      }
    if (previousProgress == null && normalizedProgress == null) {
      return false
    }
    if (
      previousProgress != null &&
        normalizedProgress != null &&
        kotlin.math.abs(previousProgress - normalizedProgress) < 0.001f
    ) {
      return false
    }
    if (normalizedProgress != null) {
      msg["uploadProgress"] = normalizedProgress
    } else {
      msg.remove("uploadProgress")
    }
    nextRow["message"] = msg
    liveMessageRowsByChat[chatId]?.put(messageId, nextRow)
    emitChangeLocked("chatMessageChanged", chatId, messageId)
    return true
  }

  private fun markLiveMessageDeletedLocked(chatId: String, messageId: String) {
    liveMessageRowsByChat[chatId]?.let { perChat ->
      perChat.remove(messageId)
      if (perChat.isEmpty()) liveMessageRowsByChat.remove(chatId)
    }
    deletedMessageIdsByChat.getOrPut(chatId) { linkedSetOf() }.add(messageId)
  }

  private fun findMessagePayloadLocked(chatId: String, messageId: String): Map<String, Any?>? {
    liveMessageRowsByChat[chatId]?.get(messageId)?.get("message")?.let { message ->
      @Suppress("UNCHECKED_CAST")
      return message as? Map<String, Any?>
    }
    val historyRows = historyRowsByChat[chatId] ?: return null
    for (row in historyRows) {
      if (normalized(row["kind"]) != "message") continue
      val message = row["message"] as? Map<*, *> ?: continue
      if (normalized(message["id"]) == messageId) {
        @Suppress("UNCHECKED_CAST")
        return message as? Map<String, Any?>
      }
    }
    return null
  }

  private fun buildLiveRowPayloadLocked(
    chatId: String,
    messageId: String,
    fromId: String?,
    type: String?,
    timestampMs: Long,
    encryptedContent: String?,
    decryptedFields: Map<String, Any?>,
    forceEdited: Boolean = false,
    forceEditedAt: Any? = null,
  ): Map<String, Any?> {
    val normalizedType = normalized(type)?.lowercase() ?: "text"
    val isMe = normalizedUpper(fromId) != null && normalizedUpper(fromId) == currentUserIdLocked()
    val text = normalized(decryptedFields["text"]) ?: ""
    val mediaUrl = normalized(decryptedFields["mediaUrl"])
    val localMediaUrl =
      normalized(decryptedFields["localMediaUrl"] ?: decryptedFields["local_media_url"])
    val fileName = normalized(decryptedFields["fileName"])
    val fileSize = parseLongValue(decryptedFields["fileSize"])
    val latitude = parseDoubleValue(decryptedFields["latitude"])
    val longitude = parseDoubleValue(decryptedFields["longitude"])
    val duration = parseDoubleValue(decryptedFields["duration"])
    val replyToId = normalized(decryptedFields["replyToId"])
    val caption = normalized(decryptedFields["caption"])
    val waveform = parseWaveformArray(decryptedFields["waveform"])
    val isEdited = forceEdited || ((decryptedFields["isEdited"] as? Boolean) == true)
    val editedAt = forceEditedAt ?: decryptedFields["editedAt"]

    val metadata = linkedMapOf<String, Any?>()
    waveform?.let { metadata["waveform"] = it }
    if (decryptedFields["width"] != null) metadata["width"] = decryptedFields["width"]
    if (decryptedFields["height"] != null) metadata["height"] = decryptedFields["height"]
    if (decryptedFields["thumbnailBase64"] != null) metadata["thumbnailBase64"] = decryptedFields["thumbnailBase64"]
    if (decryptedFields["isVideoNote"] != null) metadata["isVideoNote"] = decryptedFields["isVideoNote"]
    if (fileSize != null) metadata["fileSize"] = fileSize
    if (latitude != null) metadata["latitude"] = latitude
    if (longitude != null) metadata["longitude"] = longitude
    if (decryptedFields["viewOnce"] != null) metadata["viewOnce"] = decryptedFields["viewOnce"]
    if (decryptedFields["contact"] != null) metadata["contact"] = decryptedFields["contact"]
    if (caption != null) metadata["caption"] = caption
    if (decryptedFields["mediaKey"] != null) metadata["mediaKey"] = decryptedFields["mediaKey"]
    if (!localMediaUrl.isNullOrBlank()) metadata["localMediaUrl"] = localMediaUrl
    normalized(decryptedFields["stickerId"])?.let { metadata["stickerId"] = it }
    normalized(decryptedFields["stickerPackId"] ?: decryptedFields["packId"])?.let {
      metadata["stickerPackId"] = it
      metadata["packId"] = it
    }
    normalized(
      decryptedFields["stickerBundleFileName"] ?: decryptedFields["bundleFileName"],
    )?.let {
      metadata["stickerBundleFileName"] = it
      metadata["bundleFileName"] = it
    }
    normalized(decryptedFields["emoji"])?.let { metadata["emoji"] = it }

    val message = linkedMapOf<String, Any?>(
      "id" to messageId,
      "chatId" to chatId,
      "fromId" to fromId,
      "timestampMs" to timestampMs.toDouble(),
      "timestamp" to formatMessageTimeLabel(timestampMs),
      "text" to text,
      "type" to normalizedType,
      "status" to (if (isMe) "sent" else null),
      "isMe" to isMe,
      "isEdited" to isEdited,
      "editedAt" to editedAt,
      "encryptedContent" to encryptedContent,
      "mediaUrl" to mediaUrl,
      "localMediaUrl" to localMediaUrl,
      "fileName" to fileName,
      "duration" to duration,
      "replyToId" to replyToId,
      "caption" to caption,
      "contact" to decryptedFields["contact"],
      "metadata" to metadata.takeIf { it.isNotEmpty() },
      "bubbleShape" to mapOf(
        "showTail" to true,
        "borderTopLeftRadius" to 18,
        "borderTopRightRadius" to 18,
        "borderBottomRightRadius" to 18,
        "borderBottomLeftRadius" to 18,
      ),
    )
    return linkedMapOf<String, Any?>(
      "kind" to "message",
      "key" to "m-$messageId",
      "message" to message,
    )
  }

  private fun applyNativeIncomingMessageEventLocked(
    chatId: String,
    payload: Map<String, Any?>,
  ): String? {
    val messageId = normalized(payload["id"] ?: payload["message_id"]) ?: return null
    val fromId = normalized(payload["fromId"] ?: payload["from_id"])
    val encryptedContent = normalized(payload["encryptedContent"] ?: payload["encrypted_content"])
    val type = normalized(payload["type"]) ?: "text"
    val timestampMs = parseLongValue(payload["timestamp"]) ?: System.currentTimeMillis()
    val isMe = normalizedUpper(fromId) != null && normalizedUpper(fromId) == currentUserIdLocked()
    val rawMediaUrl = normalized(payload["mediaUrl"] ?: payload["media_url"])
    val rawFileName = normalized(payload["fileName"] ?: payload["file_name"])
    val derivedFileName =
      rawMediaUrl
        ?.substringBefore('?')
        ?.substringAfterLast('/')
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
    val encryptedLooksHybrid = isLikelyHybridCiphertext(encryptedContent)

    // Detect agent messages by fromId or explicit flag
    val isAgentMessage = (payload["isAgentMessage"] as? Boolean == true)
      || (normalized(fromId)?.lowercase() == AGENT_USER_ID)
      || (rawMediaUrl?.lowercase()?.contains("/uploads/agent-docs/") == true)
      || (rawMediaUrl?.lowercase()?.contains("/api/agent/document/") == true)
    val plainContent = normalized(payload["plainContent"] ?: payload["plain_content"])
    val agentName = normalized(payload["agentName"] ?: payload["agent_name"])

    val hadEncryptedContent = !encryptedContent.isNullOrBlank()
    val decryptedText = if (isAgentMessage && !plainContent.isNullOrBlank()) {
      // Agent messages use plainContent instead of encryption
      plainContent
    } else if (hadEncryptedContent) {
      if (!encryptedLooksHybrid) {
        encryptedContent!!
      } else {
        decryptPrivateKeyLocked()?.let { chatEngineDecryptHybridMessage(it, encryptedContent!!, isMe) }.orEmpty()
      }
    } else {
      ""
    }
    val decryptionFailed = !isAgentMessage && hadEncryptedContent && encryptedLooksHybrid && decryptedText.isEmpty()
    val decryptedFields = LinkedHashMap<String, Any?>(parseDecryptedMessagePayload(decryptedText))
    if (!rawMediaUrl.isNullOrBlank() && normalized(decryptedFields["mediaUrl"]).isNullOrBlank()) {
      decryptedFields["mediaUrl"] = rawMediaUrl
    }
    val fileNameForRow = rawFileName ?: if (type.equals("file", ignoreCase = true)) derivedFileName else null
    if (!fileNameForRow.isNullOrBlank() && normalized(decryptedFields["fileName"]).isNullOrBlank()) {
      decryptedFields["fileName"] = fileNameForRow
    }
    var row = buildLiveRowPayloadLocked(
      chatId = chatId,
      messageId = messageId,
      fromId = fromId,
      type = type,
      timestampMs = timestampMs,
      encryptedContent = encryptedContent,
      decryptedFields = decryptedFields,
    )
    // Inject agent-specific fields into the message payload for the UI layer
    if (isAgentMessage) {
      val message = ((row["message"] as? MutableMap<String, Any?>) ?: mutableMapOf())
      message["isAgentMessage"] = true
      message["isMe"] = false
      if (!agentName.isNullOrBlank()) message["agentName"] = agentName
      if (!plainContent.isNullOrBlank()) {
        message["plainContent"] = plainContent
        message["text"] = plainContent
      }
      (row as? MutableMap<String, Any?>)?.put("message", message)
    }
    // Signal decryption failure to the UI layer so it can show an appropriate indicator
    // instead of a blank bubble.
    if (decryptionFailed) {
      val message = (row["message"] as? MutableMap<String, Any?>) ?: mutableMapOf()
      message["decryptionFailed"] = true
      (row as? MutableMap<String, Any?>)?.put("message", message)
    }
    if (setOf("image", "gif", "file", "voice", "video", "music", "sticker").contains(type.lowercase(Locale.ROOT)) && isMe) {
      val existingMessage = findMessagePayloadLocked(chatId, messageId)
      val localPlaybackUrl = extractLocalPlaybackMediaUrlFromMessage(existingMessage)
      val localWaveform = extractWaveformFromMessage(existingMessage)
      if (!localPlaybackUrl.isNullOrBlank()) {
        Log.d(
          "ChatEngine",
          "preserve local media url on incoming echo chatId=$chatId messageId=$messageId local=${localPlaybackUrl.take(120)}",
        )
        row = mergeLocalPlaybackMediaUrlIntoRow(row, localPlaybackUrl)
      }
      if (extractWaveformFromMessage((row["message"] as? Map<*, *>)).isNullOrEmpty() && !localWaveform.isNullOrEmpty()) {
        Log.d(
          "ChatEngine",
          "preserve local waveform on incoming echo chatId=$chatId messageId=$messageId bars=${localWaveform.size}",
        )
        row = mergeWaveformIntoRow(row, localWaveform)
      }
    }
    upsertLiveMessageRowLocked(chatId, messageId, row)
    appendJournalLocked("native-message-row-upsert", mapOf("chatId" to chatId, "messageId" to messageId, "type" to type))
    state["updatedAt"] = System.currentTimeMillis()
    return messageId
  }

  private fun joinNativeChatTopicIfNeededLocked(chatId: String) {
    if (chatId.isBlank()) return
    loadChatHistoryIfNeededLocked(chatId)
    val client = phoenixClient ?: run {
      Log.w(
        "ChatEngine",
        "joinChat skipped reason=no_native_socket chatId=$chatId ${transportDebugStateLocked(chatId)}",
      )
      ensureNativeTransportAsync("join_chat_no_socket")
      return
    }
    if ((state["connected"] as? Boolean) != true) {
      Log.w(
        "ChatEngine",
        "joinChat skipped reason=not_connected chatId=$chatId ${transportDebugStateLocked(chatId)}",
      )
      ensureNativeTransportAsync("join_chat_not_connected")
      return
    }
    if (nativeJoinedChatIds.contains(chatId)) {
      Log.d("ChatEngine", "joinChat skipped reason=already_joined chatId=$chatId ${transportDebugStateLocked(chatId)}")
      return
    }
    if (nativeChatJoinRefsByRef.values.contains(chatId)) {
      Log.d("ChatEngine", "joinChat skipped reason=join_in_flight chatId=$chatId ${transportDebugStateLocked(chatId)}")
      return
    }
    val ref = client.join(chatTopic(chatId), emptyMap())
    nativeChatJoinRefsByRef[ref] = chatId
    Log.i(
      "ChatEngine",
      "joinChat start chatId=$chatId ref=$ref ${transportDebugStateLocked(chatId)}",
    )
    appendJournalLocked("native-chat-join-start", mapOf("chatId" to chatId, "ref" to ref))
  }

  private fun queueOutboundDraftLocked(
    chatId: String,
    messageId: String,
    payload: Map<String, Any?>,
    reason: String,
  ) {
    pendingOutboundDraftsByMessageId[messageId] = LinkedHashMap(payload)
    val ids = pendingOutboundQueueByChat.getOrPut(chatId) { mutableListOf() }
    if (ids.contains(messageId)) return
    ids.add(messageId)
    appendJournalLocked("native-outgoing-queued", mapOf("chatId" to chatId, "messageId" to messageId, "reason" to reason))
    persistOutboundStateLocked()
    emitChangeLocked("outgoingMessageQueued", chatId, messageId)
  }

  private fun removeQueuedOutboundDraftLocked(chatId: String, messageId: String, dropDraft: Boolean) {
    pendingOutboundQueueByChat[chatId]?.let { ids ->
      ids.removeAll { it == messageId }
      if (ids.isEmpty()) pendingOutboundQueueByChat.remove(chatId)
    }
    if (dropDraft) pendingOutboundDraftsByMessageId.remove(messageId)
    persistOutboundStateLocked()
  }

  private fun scheduleReplayQueuedOutboundLocked(chatId: String, trigger: String) {
    val ids = pendingOutboundQueueByChat[chatId]?.toList().orEmpty()
    if (ids.isEmpty()) return
    val inFlight = nativePendingMessagePushRefs.values.toSet()
    val drafts = ids.mapNotNull { messageId ->
      if (inFlight.contains(chatId to messageId)) return@mapNotNull null
      pendingOutboundDraftsByMessageId[messageId]
    }
    if (drafts.isEmpty()) return
    appendJournalLocked("native-outgoing-replay-scheduled", mapOf("chatId" to chatId, "count" to drafts.size, "trigger" to trigger))
    Thread {
      drafts.forEach { draft ->
        try {
          sendMessage(draft)
        } catch (_: Throwable) {
        }
      }
    }.start()
  }

  private fun chatTopic(chatId: String): String = "chat:$chatId"

  private data class LocalMediaUploadResult(
    val remoteUrl: String,
    val fileName: String?,
    val fileSize: Long?,
    val mediaKey: String?,
  )

  private sealed class LocalMediaUploadOutcome {
    data class Success(val value: LocalMediaUploadResult) : LocalMediaUploadOutcome()
    data class Failure(val reason: String) : LocalMediaUploadOutcome()
  }

  private data class LocalMediaSource(
    val bytes: ByteArray,
    val fileName: String,
    val fileSize: Long?,
  )

  private fun isLocalMediaUri(uri: String): Boolean =
    uri.startsWith("file://") || uri.startsWith("/") || uri.startsWith("content://")

  private fun extractLocalPlaybackMediaUrlFromMessage(message: Map<*, *>?): String? {
    if (message == null) return null
    val metadata = message["metadata"] as? Map<*, *>
    val candidates = listOf(
      message["localMediaUrl"],
      message["local_media_url"],
      metadata?.get("localMediaUrl"),
      metadata?.get("local_media_url"),
      message["mediaUrl"],
      message["media_url"],
      metadata?.get("mediaUrl"),
      metadata?.get("media_url"),
      message["uri"],
      metadata?.get("uri"),
      message["audioUrl"],
      message["audio_url"],
      metadata?.get("audioUrl"),
      metadata?.get("audio_url"),
    )
    for (raw in candidates) {
      val value = normalized(raw) ?: continue
      if (isLocalMediaUri(value)) return value
    }
    return null
  }

  private fun extractWaveformFromMessage(message: Map<*, *>?): List<Any?>? {
    if (message == null) return null
    val direct = message["waveform"] as? List<*>
    if (!direct.isNullOrEmpty()) return direct.toList()
    val metadata = message["metadata"] as? Map<*, *>
    val metaWaveform = metadata?.get("waveform") as? List<*>
    return if (!metaWaveform.isNullOrEmpty()) metaWaveform.toList() else null
  }

  private fun mergeLocalPlaybackMediaUrlIntoRow(
    row: Map<String, Any?>,
    localUrl: String,
  ): Map<String, Any?> {
    val mutableRow = LinkedHashMap(row)
    val messageRaw = mutableRow["message"] as? Map<*, *> ?: return mutableRow
    val mutableMessage = linkedMapOf<String, Any?>()
    messageRaw.forEach { (k, v) -> if (k != null) mutableMessage[k.toString()] = v }
    mutableMessage["localMediaUrl"] = localUrl
    val metadataRaw = mutableMessage["metadata"] as? Map<*, *>
    val mutableMetadata = linkedMapOf<String, Any?>()
    metadataRaw?.forEach { (k, v) -> if (k != null) mutableMetadata[k.toString()] = v }
    mutableMetadata["localMediaUrl"] = localUrl
    mutableMessage["metadata"] = mutableMetadata
    mutableRow["message"] = mutableMessage
    return mutableRow
  }

  private fun mergeWaveformIntoRow(
    row: Map<String, Any?>,
    waveform: List<Any?>,
  ): Map<String, Any?> {
    val mutableRow = LinkedHashMap(row)
    val messageRaw = mutableRow["message"] as? Map<*, *> ?: return mutableRow
    val mutableMessage = linkedMapOf<String, Any?>()
    messageRaw.forEach { (k, v) -> if (k != null) mutableMessage[k.toString()] = v }
    mutableMessage["waveform"] = waveform
    val metadataRaw = mutableMessage["metadata"] as? Map<*, *>
    val mutableMetadata = linkedMapOf<String, Any?>()
    metadataRaw?.forEach { (k, v) -> if (k != null) mutableMetadata[k.toString()] = v }
    mutableMetadata["waveform"] = waveform
    mutableMessage["metadata"] = mutableMetadata
    mutableRow["message"] = mutableMessage
    return mutableRow
  }

  private fun uploadCategoryForMessageType(messageType: String): String =
    when (messageType) {
      "image", "gif" -> "image"
      "voice", "music" -> "audio"
      "video" -> "video"
      else -> "file"
    }

  private fun resolveUploadUrl(apiBaseUrl: String): String? {
    val trimmed = apiBaseUrl.trim().trimEnd('/')
    if (trimmed.isBlank()) return null
    val serverBase = if (trimmed.endsWith("/api", ignoreCase = true)) {
      trimmed.dropLast(4).trimEnd('/')
    } else {
      trimmed
    }
    return if (serverBase.isBlank()) null else "$serverBase/api/media/upload"
  }

  private fun inferMimeType(fileName: String, fallbackType: String): String {
    val ext = fileName.substringAfterLast('.', "").lowercase()
    if (ext.isNotBlank()) {
      return when (ext) {
        "jpg", "jpeg" -> "image/jpeg"
        "png" -> "image/png"
        "gif" -> "image/gif"
        "webp" -> "image/webp"
        "heic" -> "image/heic"
        "m4a" -> "audio/mp4"
        "mp3" -> "audio/mpeg"
        "wav" -> "audio/wav"
        "aac" -> "audio/aac"
        "mp4" -> "video/mp4"
        "mov" -> "video/quicktime"
        else -> "application/octet-stream"
      }
    }
    return when (fallbackType) {
      "image", "gif" -> "image/jpeg"
      "voice", "music" -> "audio/mp4"
      "video" -> "video/mp4"
      else -> "application/octet-stream"
    }
  }

  private fun displayNameForContentUri(uri: Uri): String? {
    val ctx = appContextRef ?: return null
    return try {
      ctx.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
        val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
        if (index >= 0 && cursor.moveToFirst()) cursor.getString(index) else null
      }
    } catch (_: Throwable) {
      null
    }
  }

  private fun fileSizeForContentUri(uri: Uri): Long? {
    val ctx = appContextRef ?: return null
    return try {
      ctx.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
        val index = cursor.getColumnIndex(OpenableColumns.SIZE)
        if (index >= 0 && cursor.moveToFirst()) cursor.getLong(index) else null
      }
    } catch (_: Throwable) {
      null
    }
  }

  private fun resolveLocalMediaSource(
    localUri: String,
    fileNameHint: String?,
    messageType: String,
  ): LocalMediaSource? {
    val ctx = appContextRef ?: return null
    val parsed = try { Uri.parse(localUri) } catch (_: Throwable) { null }
    if (parsed != null && parsed.scheme.equals("content", ignoreCase = true)) {
      val input = try { ctx.contentResolver.openInputStream(parsed) } catch (_: Throwable) { null } ?: return null
      input.use { stream ->
        val bytes = try { stream.readBytes() } catch (_: Throwable) { return null }
        val resolvedName = fileNameHint
          ?: displayNameForContentUri(parsed)
          ?: "upload_${System.currentTimeMillis()}"
        val size = fileSizeForContentUri(parsed) ?: bytes.size.toLong()
        return LocalMediaSource(bytes = bytes, fileName = resolvedName, fileSize = size)
      }
    }

    val file = try {
      when {
        localUri.startsWith("file://") -> File(Uri.parse(localUri).path ?: "")
        localUri.startsWith("/") -> File(localUri)
        else -> File(localUri)
      }
    } catch (_: Throwable) {
      return null
    }
    if (!file.exists() || !file.isFile) return null
    val resolvedName = fileNameHint
      ?: file.name.takeIf { it.isNotBlank() }
      ?: "upload_${System.currentTimeMillis()}"
    val bytes = try {
      file.readBytes()
    } catch (_: Throwable) {
      return null
    }
    return LocalMediaSource(bytes = bytes, fileName = resolvedName, fileSize = file.length())
  }

  private fun uploadLocalMediaLocked(
    localUri: String,
    messageType: String,
    fileNameHint: String?,
    userId: String,
    token: String,
    apiBaseUrl: String,
    messageId: String? = null,
    onProgress: ((Float) -> Unit)? = null,
  ): LocalMediaUploadOutcome {
    val uploadUrl = resolveUploadUrl(apiBaseUrl) ?: return LocalMediaUploadOutcome.Failure("invalid_upload_url")
    val source = resolveLocalMediaSource(localUri, fileNameHint, messageType)
      ?: return LocalMediaUploadOutcome.Failure("media_file_missing")
    val originalFileSize = source.fileSize ?: source.bytes.size.toLong()
    val uploadBytes: ByteArray
    val mediaKey: String?
    if (chatEngineShouldEncryptUploadedMediaType(messageType)) {
      try {
        val encrypted = chatEngineEncryptMediaBytes(source.bytes)
        uploadBytes = encrypted.first
        mediaKey = encrypted.second
      } catch (t: Throwable) {
        Log.w(
          "ChatEngine",
          "uploadLocalMedia encryptFailure type=$messageType fileName=${source.fileName} error=${t.message ?: t.javaClass.simpleName}",
          t,
        )
        return LocalMediaUploadOutcome.Failure("media_encrypt_failed")
      }
    } else {
      uploadBytes = source.bytes
      mediaKey = null
    }
    val resolvedMime = inferMimeType(source.fileName, messageType)
    val uploadBody = uploadBytes.toRequestBody(resolvedMime.toMediaTypeOrNull())
    Log.d(
      "ChatEngine",
      "uploadLocalMedia start type=$messageType fileName=${source.fileName} fileSize=${source.fileSize ?: -1} localUri=${localUri.take(160)} url=${uploadUrl.take(160)}",
    )
    val multipart = MultipartBody.Builder()
      .setType(MultipartBody.FORM)
      .addFormDataPart("file", source.fileName, uploadBody)
      .addFormDataPart("user_id", userId)
      .addFormDataPart("type", uploadCategoryForMessageType(messageType))
      .build()
      
    val progressBody = object : RequestBody() {
      override fun contentType() = multipart.contentType()
      override fun contentLength() = multipart.contentLength()
      override fun writeTo(sink: okio.BufferedSink) {
        val countingSink = object : okio.ForwardingSink(sink) {
          private var bytesWritten = 0L
          private val totalLength = contentLength()
          private var lastEmitMs = 0L
          private var lastEmitProgress = 0f
          override fun write(source: okio.Buffer, byteCount: Long) {
            super.write(source, byteCount)
            bytesWritten += byteCount
            if (totalLength > 0) {
              val progress = (bytesWritten.toFloat() / totalLength.toFloat()).coerceIn(0f, 1f)
              val now = System.currentTimeMillis()
              if (
                progress >= 1f ||
                  (progress - lastEmitProgress) >= uploadProgressStep ||
                  (now - lastEmitMs) >= uploadProgressFrameIntervalMs
              ) {
                lastEmitMs = now
                lastEmitProgress = progress
                onProgress?.invoke(progress)
              }
            }
          }
        }
        val bufferedSink = countingSink.buffer()
        multipart.writeTo(bufferedSink)
        bufferedSink.flush()
      }
    }

    val request = Request.Builder()
      .url(uploadUrl)
      .post(progressBody)
      .header("ngrok-skip-browser-warning", "true")
      .header("Authorization", "Bearer $token")
      .build()
    val call = mediaUploadHttpClient.newCall(request)
    if (!messageId.isNullOrBlank()) {
      synchronized(lock) {
        activeMediaUploadCallsByMessageId[messageId] = call
      }
    }
    val response = try {
      call.execute()
    } catch (t: Throwable) {
      if (!messageId.isNullOrBlank()) {
        synchronized(lock) {
          if (activeMediaUploadCallsByMessageId[messageId] === call) {
            activeMediaUploadCallsByMessageId.remove(messageId)
          }
        }
      }
      val reason =
        if (call.isCanceled() || t.message?.contains("canceled", ignoreCase = true) == true) {
          "upload_canceled"
        } else if (t is SocketTimeoutException || t is InterruptedIOException) {
          "upload_timeout"
        } else {
          "upload_failed"
        }
      Log.w(
        "ChatEngine",
        "uploadLocalMedia exception type=$messageType fileName=${source.fileName} reason=$reason error=${t.message ?: t.javaClass.simpleName}",
        t,
      )
      return LocalMediaUploadOutcome.Failure(reason)
    }
    response.use { res ->
      if (!messageId.isNullOrBlank()) {
        synchronized(lock) {
          if (activeMediaUploadCallsByMessageId[messageId] === call) {
            activeMediaUploadCallsByMessageId.remove(messageId)
          }
        }
      }
      if (!res.isSuccessful) {
        Log.w(
          "ChatEngine",
          "uploadLocalMedia httpFailure type=$messageType fileName=${source.fileName} code=${res.code}",
        )
        return LocalMediaUploadOutcome.Failure("upload_failed")
      }
      val body = try { res.body?.string() } catch (_: Throwable) { null } ?: return LocalMediaUploadOutcome.Failure("upload_failed")
      val remoteUrl = try {
        val json = JSONObject(body)
        normalized(json.opt("url") ?: json.opt("mediaUrl") ?: json.opt("media_url"))
      } catch (_: Throwable) {
        null
      } ?: return LocalMediaUploadOutcome.Failure("invalid_upload_response")
      Log.i(
        "ChatEngine",
        "uploadLocalMedia success type=$messageType fileName=${source.fileName} remoteUrl=${remoteUrl.take(160)}",
      )
      return LocalMediaUploadOutcome.Success(
        LocalMediaUploadResult(
          remoteUrl = remoteUrl,
          fileName = source.fileName,
          fileSize = originalFileSize,
          mediaKey = mediaKey,
        ),
      )
    }
  }

  private fun loadChatHistoryIfNeededLocked(chatId: String, force: Boolean = false) {
    if (chatId.isBlank()) return
    if (historyLoadingChats.contains(chatId)) return
    if (!force && historyRowsByChat.containsKey(chatId)) return
    val isBridgeText = isBridgeTextModeLocked()
    val apiBaseUrl = apiBaseUrlLocked()
    val bridgeUrl = bridgeUrlLocked("/bridge/v1/chat/history")
    val userId = normalized(getConfigValueLocked("userId"))
    if ((if (isBridgeText) bridgeUrl.isNullOrBlank() else apiBaseUrl.isNullOrBlank()) || userId.isNullOrBlank()) {
      appendJournalLocked(
        "native-chat-history-skip",
        mapOf("chatId" to chatId, "reason" to "missing_config"),
      )
      return
    }
    historyLoadingChats.add(chatId)
    appendJournalLocked("native-chat-history-load-start", mapOf("chatId" to chatId))

    val directHistoryUrl = "$apiBaseUrl/api/chat/$chatId/messages?limit=$chatHistoryFetchLimit"
    val requestBuilder = Request.Builder()
      .url(if (isBridgeText) bridgeUrl!! else directHistoryUrl)
      .header("Accept", "application/json")
      .header("ngrok-skip-browser-warning", "true")
    if (isBridgeText) {
      requestBuilder
        .post(
          JSONObject(
            mapOf(
              "chatId" to chatId,
              "userId" to userId,
              "limit" to chatHistoryFetchLimit,
            ),
          ).toString().toRequestBody("application/json".toMediaTypeOrNull()),
        )
        .header("Content-Type", "application/json")
    } else {
      requestBuilder.get()
    }
    authHeaderTokenLocked()?.takeIf { it.isNotBlank() }?.let {
      requestBuilder.header("Authorization", "Bearer $it")
    }
    historyHttpClient.newCall(requestBuilder.build()).enqueue(object : Callback {
      override fun onFailure(call: Call, e: IOException) {
        synchronized(lock) {
          historyLoadingChats.remove(chatId)
          appendJournalLocked(
            "native-chat-history-load-error",
            mapOf("chatId" to chatId, "error" to (e.message ?: "network_error")),
          )
          emitChangeLocked("engineError", chatId, null)
        }
      }

      override fun onResponse(call: Call, response: Response) {
        response.use { res ->
          val bodyString = try { res.body?.string() } catch (_: Throwable) { null }
          synchronized(lock) {
            historyLoadingChats.remove(chatId)
            if (!res.isSuccessful || bodyString == null) {
              appendJournalLocked(
                "native-chat-history-load-error",
                mapOf("chatId" to chatId, "status" to res.code),
              )
              return
            }
            applyChatHistoryResponseLocked(chatId, bodyString)
          }
        }
      }
    })
  }

  private fun applyChatHistoryResponseLocked(chatId: String, bodyString: String) {
    try {
      val messages = if (bodyString.trimStart().startsWith("[")) {
        JSONArray(bodyString)
      } else {
        val json = JSONObject(bodyString)
        (json.optJSONArray("messages") ?: json.optJSONArray("data") ?: JSONArray())
      }
      val remoteRows = buildHistoryRowsLocked(chatId, messages)
      val existingRowsCount = historyRowsByChat[chatId]?.size ?: 0
      val liveRowsCount = liveMessageRowsByChat[chatId]?.size ?: 0
      val rows = mergedStoredHistoryRowsLocked(chatId, remoteRows)
      historyRowsByChat[chatId] = rows.toMutableList()
      state["updatedAt"] = System.currentTimeMillis()
      Log.i(
        "ChatEngine",
        "loadChatHistory MERGE chatId=$chatId limit=$chatHistoryFetchLimit remoteRows=${remoteRows.size} existingRows=$existingRowsCount liveRows=$liveRowsCount mergedRows=${rows.size}",
      )
      appendJournalLocked(
        "native-chat-history-load-ok",
        mapOf(
          "chatId" to chatId,
          "rows" to rows.size,
          "remoteRows" to remoteRows.size,
          "existingRows" to existingRowsCount,
          "liveRows" to liveRowsCount,
          "messages" to messages.length(),
          "limit" to chatHistoryFetchLimit,
        ),
      )
      scheduleReplayQueuedOutboundLocked(chatId, "history_loaded")
      emitChangeLocked("chatRowsReloaded", chatId, null)
    } catch (e: Throwable) {
      appendJournalLocked(
        "native-chat-history-load-error",
        mapOf("chatId" to chatId, "error" to (e.message ?: "invalid_json")),
      )
    }
  }

  private fun buildHistoryRowsLocked(chatId: String, messages: JSONArray): List<Map<String, Any?>> {
    val rawMessages = ArrayList<JSONObject>(messages.length())
    for (i in 0 until messages.length()) {
      messages.optJSONObject(i)?.let { rawMessages.add(it) }
    }
    rawMessages.sortBy {
      parseLongValue(it.opt("timestamp") ?: it.opt("timestampMs") ?: it.opt("timestamp_ms")) ?: 0L
    }
    val rows = ArrayList<Map<String, Any?>>(rawMessages.size)
    for (raw in rawMessages) {
      val messageId = normalized(raw.opt("id") ?: raw.opt("message_id")) ?: continue
      val fromId = normalized(raw.opt("fromId") ?: raw.opt("from_id"))
      val type = normalized(raw.opt("type")) ?: "text"
      val timestampMs =
        parseLongValue(raw.opt("timestamp") ?: raw.opt("timestampMs") ?: raw.opt("timestamp_ms"))
          ?: System.currentTimeMillis()
      val encryptedContent = normalized(raw.opt("encryptedContent") ?: raw.opt("encrypted_content"))
      val plaintextFallback = normalized(raw.opt("plaintext") ?: raw.opt("text")).orEmpty()
      val serverStatus = normalized(raw.opt("status"))?.lowercase()
      val isEdited = raw.opt("isEdited") as? Boolean ?: false
      val editedAt = raw.opt("editedAt") ?: raw.opt("edited_at")
      val rawMediaUrl = normalized(raw.opt("mediaUrl") ?: raw.opt("media_url"))
      val rawFileName = normalized(raw.opt("fileName") ?: raw.opt("file_name"))
      val derivedFileName =
        rawMediaUrl
          ?.substringBefore('?')
          ?.substringAfterLast('/')
          ?.trim()
          ?.takeIf { it.isNotEmpty() }
      val isMe = normalizedUpper(fromId) != null && normalizedUpper(fromId) == currentUserIdLocked()
      val encryptedLooksHybrid = isLikelyHybridCiphertext(encryptedContent)
      val historyIsAgent = (raw.opt("isAgentMessage") as? Boolean == true)
        || (normalized(fromId)?.lowercase() == AGENT_USER_ID)
        || (rawMediaUrl?.lowercase()?.contains("/uploads/agent-docs/") == true)
        || (rawMediaUrl?.lowercase()?.contains("/api/agent/document/") == true)
      val agentPlainContent = normalized(raw.opt("plainContent") ?: raw.opt("plain_content"))
        ?: normalized(encryptedContent)

      val hadEncryptedContent = !encryptedContent.isNullOrBlank()
      var historyDecryptionFailed = false
      val decryptedFields = if (historyIsAgent) {
        if (!agentPlainContent.isNullOrBlank()) {
          mapOf("text" to agentPlainContent)
        } else {
          emptyMap()
        }
      } else if (hadEncryptedContent) {
        if (!encryptedLooksHybrid) {
          parseDecryptedMessagePayload(encryptedContent!!)
        } else {
          val privateKey = decryptPrivateKeyLocked()
          val decrypted = privateKey?.let { chatEngineDecryptHybridMessage(it, encryptedContent!!, isMe) }.orEmpty()
          if (decrypted.trim().isEmpty() && plaintextFallback.isNotBlank()) {
            historyDecryptionFailed = true
            mapOf("text" to plaintextFallback)
          } else if (decrypted.trim().isEmpty()) {
            historyDecryptionFailed = true
            emptyMap()
          } else {
            val parsed = parseDecryptedMessagePayload(decrypted)
            if (parsed.isEmpty() && plaintextFallback.isNotBlank()) {
              historyDecryptionFailed = true
              mapOf("text" to plaintextFallback)
            } else if (parsed.isEmpty()) {
              historyDecryptionFailed = true
              emptyMap()
            } else {
              parsed
            }
          }
        }
      } else if (plaintextFallback.isNotBlank()) {
        mapOf("text" to plaintextFallback)
      } else {
        emptyMap()
      }

      val enrichedFields = LinkedHashMap<String, Any?>(decryptedFields)
      if (!rawMediaUrl.isNullOrBlank() && normalized(enrichedFields["mediaUrl"]).isNullOrBlank()) {
        enrichedFields["mediaUrl"] = rawMediaUrl
      }
      val fileNameForRow = rawFileName ?: if (type.equals("file", ignoreCase = true)) derivedFileName else null
      if (!fileNameForRow.isNullOrBlank() && normalized(enrichedFields["fileName"]).isNullOrBlank()) {
        enrichedFields["fileName"] = fileNameForRow
      }

      val row = (buildLiveRowPayloadLocked(
        chatId = chatId,
        messageId = messageId,
        fromId = fromId,
        type = type,
        timestampMs = timestampMs,
        encryptedContent = encryptedContent,
        decryptedFields = enrichedFields,
        forceEdited = isEdited,
        forceEditedAt = editedAt,
      ).toMutableMap())
      val message = (row["message"] as? Map<String, Any?>)?.toMutableMap() ?: mutableMapOf()
      if (historyIsAgent) {
        message["isAgentMessage"] = true
        message["isMe"] = false
        val name = normalized(raw.opt("agentName") ?: raw.opt("agent_name"))
        if (!name.isNullOrBlank()) message["agentName"] = name
        if (!agentPlainContent.isNullOrBlank() && agentPlainContent.isNotBlank()) {
          message["plainContent"] = agentPlainContent
          message["text"] = agentPlainContent
        }
      }
      if (!serverStatus.isNullOrBlank()) message["status"] = serverStatus
      val reactionEmoji = normalized(raw.opt("reactionEmoji") ?: raw.opt("reaction_emoji"))
      if (!reactionEmoji.isNullOrBlank()) message["reactionEmoji"] = reactionEmoji
      if (!historyIsAgent && hadEncryptedContent && encryptedLooksHybrid && historyDecryptionFailed) {
        message["decryptionFailed"] = true
      }
      row["message"] = message
      rows.add(row)
    }
    return rows
  }

  private fun onNativeSocketOpen(userTopic: String) {
    synchronized(lock) {
      val client = phoenixClient ?: return
      state["connected"] = true
      state["state"] = "native-socket-open"
      state["updatedAt"] = System.currentTimeMillis()
      state["note"] = "ChatEngine native Phoenix socket open"
      appendJournalLocked("native-socket-open", emptyMap())
      nativeUserTopic = userTopic
      nativeUserJoinRef = client.join(userTopic, emptyMap())
      Log.i(
        "ChatEngine",
        "nativeSocket open userTopic=$userTopic userJoinRef=$nativeUserJoinRef openChatIds=${openChatChannels.keys} ${transportDebugStateLocked()}",
      )
      nativeChatJoinRefsByRef.clear()
      nativeJoinedChatIds.clear()
      nativePendingMessagePushRefs.clear()
      nativePendingEditPushRefs.clear()
      nativePendingDeletePushRefs.clear()
      nativeTypingStateByChatId.clear()
      peerTypingUserIdsByChatId.clear()
      nativeRecordingStateByChatId.clear()
      pinnedMessagesByChatId.clear()
      pinnedFetchInFlightChatIds.clear()
      historyLoadingChats.clear()
      liveMessageRowsByChat.clear()
      deletedMessageIdsByChat.clear()
      openChatChannels.keys.forEach { joinNativeChatTopicIfNeededLocked(it) }
      emitChangeLocked("connectionStateChanged", null, null)
    }
  }

  private fun onNativeSocketClosed(code: Int, reason: String?) {
    synchronized(lock) {
      Log.w(
        "ChatEngine",
        "nativeSocket closed code=$code reason=${reason ?: "-"} ${transportDebugStateLocked()}",
      )
      val inFlightMessages = nativePendingMessagePushRefs.values.toList()
      inFlightMessages.forEach { (chatId, messageId) ->
        upsertLocalStatusLocked(chatId, messageId, "pending")
        pendingOutboundDraftsByMessageId[messageId]?.let { draft ->
          queueOutboundDraftLocked(chatId, messageId, draft, "socket_closed")
        }
      }
      nativePresenceActive = false
      nativeUserJoinRef = null
      nativeChatJoinRefsByRef.clear()
      nativeJoinedChatIds.clear()
      nativePendingMessagePushRefs.clear()
      nativePendingEditPushRefs.clear()
      nativePendingDeletePushRefs.clear()
      nativeTypingStateByChatId.clear()
      peerTypingUserIdsByChatId.clear()
      nativeRecordingStateByChatId.clear()
      pinnedMessagesByChatId.clear()
      pinnedFetchInFlightChatIds.clear()
      historyLoadingChats.clear()
      liveMessageRowsByChat.clear()
      deletedMessageIdsByChat.clear()
      state["connected"] = false
      state["state"] = "native-socket-closed"
      state["updatedAt"] = System.currentTimeMillis()
      state["presenceSource"] = "shadow"
      appendJournalLocked(
        "native-socket-closed",
        mapOf("code" to code, "reason" to reason),
      )
      emitChangeLocked("connectionStateChanged", null, null)
    }
  }

  private fun onNativeSocketError(error: String) {
    synchronized(lock) {
      Log.e(
        "ChatEngine",
        "nativeSocket error error=$error ${transportDebugStateLocked()}",
      )
      state["updatedAt"] = System.currentTimeMillis()
      state["lastNativeSocketError"] = error
      appendJournalLocked("native-socket-error", mapOf("error" to error))
      emitChangeLocked("engineError", null, null)
    }
  }

  private fun onNativeSocketEvent(frame: ChatTransportEvent) {
    val topic = frame.topic
    val event = frame.event
    val payload = frame.payload
    val ref = frame.ref
    val joinRef = frame.joinRef
    synchronized(lock) {
      if (
        event == "phx_reply" ||
          event == "message" ||
          event == "typing" ||
          event == "stop-typing" ||
          event == "delivery-receipt" ||
          event == "read-receipt"
      ) {
        Log.d(
          "ChatEngine",
          "socketEvent topic=$topic event=$event ref=${ref ?: "-"} joinRef=${joinRef ?: "-"} payloadKeys=${payload.keys.sorted()}",
        )
      }
      if (
        event == "phx_reply" &&
          topic == nativeUserTopic &&
          !ref.isNullOrBlank() &&
          ref == nativeUserJoinRef &&
          normalized(payload["status"]) == "ok"
      ) {
        nativePresenceActive = true
        state["presenceSource"] = "native"
        state["userChannelState"] = "joined"
        state["updatedAt"] = System.currentTimeMillis()
        appendJournalLocked("native-user-joined", mapOf("topic" to topic))
        emitChangeLocked("connectionStateChanged", null, null)
        return
      }
      if (event == "phx_reply" && !ref.isNullOrBlank()) {
        val joinedChatId = nativeChatJoinRefsByRef.remove(ref)
        if (!joinedChatId.isNullOrBlank()) {
          val status = normalized(payload["status"])?.lowercase().orEmpty()
          Log.i(
            "ChatEngine",
            "joinChat reply chatId=$joinedChatId ref=$ref status=$status payload=$payload ${transportDebugStateLocked(joinedChatId)}",
          )
          if (status == "ok") {
            nativeJoinedChatIds.add(joinedChatId)
            appendJournalLocked("native-chat-joined", mapOf("chatId" to joinedChatId))
            scheduleReplayQueuedOutboundLocked(joinedChatId, "chat_joined")
          } else {
            appendJournalLocked("native-chat-join-error", mapOf("chatId" to joinedChatId, "status" to status))
          }
          state["updatedAt"] = System.currentTimeMillis()
          emitChangeLocked("chatChannelStateChanged", joinedChatId, null)
          return
        }

        val pending = nativePendingMessagePushRefs.remove(ref)
        if (pending != null) {
          val (chatId, messageId) = pending
          val status = normalized(payload["status"])?.lowercase().orEmpty()
          val nextStatus = if (status == "ok") "sent" else "error"
          Log.i(
            "ChatEngine",
            "sendMessage reply chatId=$chatId messageId=$messageId ref=$ref status=$status nextStatus=$nextStatus payload=$payload ${transportDebugStateLocked(chatId)}",
          )
          if (status == "ok") {
            removeQueuedOutboundDraftLocked(chatId, messageId, dropDraft = true)
          }
          upsertLocalStatusLocked(chatId, messageId, nextStatus)
          appendJournalLocked(
            "native-message-push-reply",
            mapOf("chatId" to chatId, "messageId" to messageId, "ref" to ref, "status" to status),
          )
          emitChangeLocked("messageStatusChanged", chatId, messageId)
          return
        }

        val pendingEdit = nativePendingEditPushRefs.remove(ref)
        if (pendingEdit != null) {
          val (chatId, messageId) = pendingEdit
          val status = normalized(payload["status"])?.lowercase().orEmpty()
          Log.i(
            "ChatEngine",
            "editMessage reply chatId=$chatId messageId=$messageId ref=$ref status=$status payload=$payload",
          )
          appendJournalLocked(
            "native-edit-message-push-reply",
            mapOf("chatId" to chatId, "messageId" to messageId, "ref" to ref, "status" to status),
          )
          emitChangeLocked("chatMessageEdited", chatId, messageId)
          return
        }

        val pendingDelete = nativePendingDeletePushRefs.remove(ref)
        if (pendingDelete != null) {
          val (chatId, messageId) = pendingDelete
          val status = normalized(payload["status"])?.lowercase().orEmpty()
          Log.i(
            "ChatEngine",
            "deleteMessage reply chatId=$chatId messageId=$messageId ref=$ref status=$status payload=$payload",
          )
          if (status == "ok") {
            removeMessageIndicesLocked(chatId, messageId)
          }
          appendJournalLocked(
            "native-delete-message-push-reply",
            mapOf("chatId" to chatId, "messageId" to messageId, "ref" to ref, "status" to status),
          )
          emitChangeLocked("chatMessageDeleted", chatId, messageId)
          return
        }
        Log.w(
          "ChatEngine",
          "socketEvent unmatched phx_reply topic=$topic ref=$ref payload=$payload ${transportDebugStateLocked()}",
        )
      }
      if (topic.startsWith("chat:")) {
        val chatId = topic.removePrefix("chat:")
        if (event == "typing" || event == "stop-typing") {
          val isTypingEvent = event == "typing"
          val payloadUserId = normalizedUpper(payload["userId"] ?: payload["user_id"] ?: payload["id"])
          val myUserId = normalizedUpper(getConfigValueLocked("userId"))
          if (payloadUserId != null && payloadUserId != myUserId) {
            val typingUsers = peerTypingUserIdsByChatId.getOrPut(chatId) { linkedSetOf() }
            if (isTypingEvent) {
              typingUsers.add(payloadUserId)
            } else {
              typingUsers.remove(payloadUserId)
            }
            if (typingUsers.isEmpty()) {
              peerTypingUserIdsByChatId.remove(chatId)
            }
          } else if (!isTypingEvent) {
            peerTypingUserIdsByChatId.remove(chatId)
          }
          val isAnyTyping =
            peerTypingUserIdsByChatId[chatId]?.isNotEmpty() == true || (isTypingEvent && payloadUserId == null)
          emitChangeLocked("peerTyping", chatId, if (isAnyTyping) "true" else "false")
          return
        }
        if (event == "pinned-updated") {
          val messageId = normalized(payload["messageId"] ?: payload["message_id"]) ?: return
          val pinned = parseBooleanValue(payload["pinned"]) ?: true
          applyPinnedUpdateLocked(
            chatId = chatId,
            messageId = messageId,
            pinned = pinned,
            payload = payload,
            trigger = "socket_pinned_updated",
            refreshRemote = true,
          )
          emitChangeLocked("chatPinnedUpdated", chatId, messageId)
          return
        }
        if (event == "message") {
          val insertedMessageId = applyNativeIncomingMessageEventLocked(chatId, payload)
          if (!insertedMessageId.isNullOrBlank()) {
            val fromId = normalized(payload["fromId"] ?: payload["from_id"])
            val myUserId = normalizedUpper(getConfigValueLocked("userId"))
            val isMe = normalizedUpper(fromId) == myUserId
            if (!isMe) {
              sendDeliveryReceipt(mapOf("chatId" to chatId, "messageId" to insertedMessageId))
            }

            if (peerTypingUserIdsByChatId[chatId] != null) {
              peerTypingUserIdsByChatId.remove(chatId)
              emitChangeLocked("peerTyping", chatId, "false")
            }
            emitChangeLocked("chatMessageInserted", chatId, insertedMessageId)
            return
          }
        }
        val mutationUpdate = applyNativeChatMutationEventLocked(chatId, event, payload)
        if (mutationUpdate != null) {
          val reason = when (mutationUpdate.second) {
            "edited" -> "chatMessageEdited"
            "deleted" -> "chatMessageDeleted"
            else -> "chatMessageChanged"
          }
          emitChangeLocked(reason, chatId, mutationUpdate.first)
          return
        }
        val receiptUpdate = applyNativeChatEventLocked(chatId, event, payload)
        if (receiptUpdate != null) {
          emitChangeLocked("messageStatusChanged", chatId, receiptUpdate.first)
          return
        }
      }
      if (topic != nativeUserTopic) return
      if (applyPresenceEventLocked(event, payload)) {
        state["presenceSource"] = "native"
        state["updatedAt"] = System.currentTimeMillis()
        emitChangeLocked("presenceChanged", null, null)
      }
    }
  }

  private fun applyPresenceEventLocked(event: String, payload: Map<String, Any?>): Boolean =
    when (event) {
      "initial-presence" -> {
        onlineUsers.clear()
        ((payload["onlineFriendIds"] as? List<*>) ?: emptyList<Any?>())
          .mapNotNullTo(onlineUsers) { normalizedUpper(it) }
        onlineUsers.forEach { userId -> lastSeenByUserId.remove(userId) }
        appendJournalLocked("native-presence-initial", mapOf("count" to onlineUsers.size))
        true
      }

      "friend-online" -> {
        val userId = normalizedUpper(payload["userId"] ?: payload["user_id"] ?: payload["id"]) ?: return false
        onlineUsers.add(userId)
        lastSeenByUserId.remove(userId)
        appendJournalLocked("native-presence-online", mapOf("userId" to userId))
        true
      }

      "friend-offline" -> {
        val userId = normalizedUpper(payload["userId"] ?: payload["user_id"] ?: payload["id"]) ?: return false
        onlineUsers.remove(userId)
        val lastSeen =
          parseLongValue(
            payload["lastSeenMs"] ?: payload["last_seen_ms"] ?: payload["lastSeen"] ?: payload["last_seen"],
          ) ?: System.currentTimeMillis()
        lastSeenByUserId[userId] = lastSeen
        appendJournalLocked("native-presence-offline", mapOf("userId" to userId, "lastSeenMs" to lastSeen))
        true
      }

      "presence_state" -> {
        onlineUsers.clear()
        payload.keys.mapNotNullTo(onlineUsers) { normalizedUpper(it) }
        onlineUsers.forEach { userId -> lastSeenByUserId.remove(userId) }
        appendJournalLocked("native-presence-state", mapOf("count" to onlineUsers.size))
        true
      }

      "presence_diff", "presence-diff" -> {
        val joins = (payload["joins"] as? Map<*, *>) ?: emptyMap<String, Any?>()
        val leaves = (payload["leaves"] as? Map<*, *>) ?: emptyMap<String, Any?>()
        joins.keys.forEach { key ->
          normalizedUpper(key)?.let {
            onlineUsers.add(it)
            lastSeenByUserId.remove(it)
          }
        }
        leaves.keys.forEach { key ->
          normalizedUpper(key)?.let {
            onlineUsers.remove(it)
            lastSeenByUserId[it] = System.currentTimeMillis()
          }
        }
        appendJournalLocked(
          "native-presence-diff",
          mapOf("joins" to joins.size, "leaves" to leaves.size),
        )
        true
      }

      else -> false
    }

  private fun applyNativeChatMutationEventLocked(
    chatId: String,
    event: String,
    payload: Map<String, Any?>,
  ): Pair<String, String>? {
    if (chatId.isBlank()) return null
    val messageId = normalized(payload["messageId"] ?: payload["message_id"]) ?: return null
    return when (event) {
      "message-edited" -> {
        val encryptedContent = normalized(payload["encryptedContent"] ?: payload["encrypted_content"])
        val editedAt = payload["editedAt"] ?: payload["edited_at"]
        val existingRow = liveMessageRowsByChat[chatId]?.get(messageId)
        val existingMessage = existingRow?.get("message") as? Map<*, *>
        val fromId = normalized(existingMessage?.get("fromId"))
        val type = normalized(existingMessage?.get("type")) ?: "text"
        val timestampMs =
          parseLongValue(existingMessage?.get("timestampMs"))
            ?: parseLongValue(existingMessage?.get("timestamp"))
            ?: System.currentTimeMillis()
        val isMe = normalizedUpper(fromId) != null && normalizedUpper(fromId) == currentUserIdLocked()
        val decryptedFields = if (!encryptedContent.isNullOrBlank()) {
          if (!isLikelyHybridCiphertext(encryptedContent)) {
            parseDecryptedMessagePayload(encryptedContent)
          } else {
            val decrypted = decryptPrivateKeyLocked()?.let { chatEngineDecryptHybridMessage(it, encryptedContent, isMe) }.orEmpty()
            parseDecryptedMessagePayload(decrypted)
          }
        } else {
          emptyMap()
        }
        val row = buildLiveRowPayloadLocked(
          chatId = chatId,
          messageId = messageId,
          fromId = fromId,
          type = type,
          timestampMs = timestampMs,
          encryptedContent = encryptedContent ?: normalized(existingMessage?.get("encryptedContent")),
          decryptedFields = decryptedFields,
          forceEdited = true,
          forceEditedAt = editedAt,
        )
        upsertLiveMessageRowLocked(chatId, messageId, row)
        state["updatedAt"] = System.currentTimeMillis()
        appendJournalLocked(
          "native-message-edited",
          mapOf(
            "chatId" to chatId,
            "messageId" to messageId,
            "editedAt" to editedAt,
          ),
        )
        messageId to "edited"
      }

      "message-deleted" -> {
        removeMessageIndicesLocked(chatId, messageId)
        markLiveMessageDeletedLocked(chatId, messageId)
        applyPinnedUpdateLocked(
          chatId = chatId,
          messageId = messageId,
          pinned = false,
          payload = emptyMap(),
          trigger = "message_deleted",
          refreshRemote = false,
        )
        state["updatedAt"] = System.currentTimeMillis()
        appendJournalLocked("native-message-deleted", mapOf("chatId" to chatId, "messageId" to messageId))
        messageId to "deleted"
      }

      else -> null
    }
  }

  private fun applyNativeChatEventLocked(
    chatId: String,
    event: String,
    payload: Map<String, Any?>,
  ): Pair<String, String>? {
    if (chatId.isBlank()) return null
    val messageId = normalized(payload["messageId"] ?: payload["message_id"]) ?: return null
    return when (event) {
      "message-delivered" -> {
        val chatMap = receiptIndex.getOrPut(chatId) { linkedMapOf() }
        chatMap[messageId] = strongerStatus(chatMap[messageId], "delivered")
        upsertLocalStatusLocked(chatId, messageId, "delivered")
        state["updatedAt"] = System.currentTimeMillis()
        appendJournalLocked("native-message-delivered", mapOf("chatId" to chatId, "messageId" to messageId))
        messageId to "delivered"
      }

      "message-read" -> {
        val chatMap = receiptIndex.getOrPut(chatId) { linkedMapOf() }
        chatMap[messageId] = strongerStatus(chatMap[messageId], "read")
        upsertLocalStatusLocked(chatId, messageId, "read")
        state["updatedAt"] = System.currentTimeMillis()
        appendJournalLocked("native-message-read", mapOf("chatId" to chatId, "messageId" to messageId))
        messageId to "read"
      }

      else -> null
    }
  }

  private fun fetchPinnedMessagesLocked(chatId: String, trigger: String) {
    if (chatId.isBlank()) return
    if (pinnedFetchInFlightChatIds.contains(chatId)) return
    val apiBaseUrl = apiBaseUrlLocked() ?: return
    val token = authHeaderTokenLocked()

    pinnedFetchInFlightChatIds.add(chatId)
    appendJournalLocked(
      "native-pinned-load-start",
      mapOf("chatId" to chatId, "trigger" to trigger),
    )

    val requestBuilder = Request.Builder()
      .url("$apiBaseUrl/api/chat/$chatId/pinned_messages")
      .get()
      .header("Accept", "application/json")
      .header("ngrok-skip-browser-warning", "true")
    token?.takeIf { it.isNotBlank() }?.let {
      requestBuilder.header("Authorization", "Bearer $it")
    }

    historyHttpClient.newCall(requestBuilder.build()).enqueue(object : Callback {
      override fun onFailure(call: Call, e: IOException) {
        synchronized(lock) {
          pinnedFetchInFlightChatIds.remove(chatId)
          appendJournalLocked(
            "native-pinned-load-error",
            mapOf(
              "chatId" to chatId,
              "trigger" to trigger,
              "error" to (e.message ?: "network_error"),
            ),
          )
          emitChangeLocked("chatPinnedUpdated", chatId, null)
        }
      }

      override fun onResponse(call: Call, response: Response) {
        response.use { res ->
          synchronized(lock) {
            pinnedFetchInFlightChatIds.remove(chatId)
            val body = res.body?.string().orEmpty()
            if (!res.isSuccessful) {
              appendJournalLocked(
                "native-pinned-load-error",
                mapOf(
                  "chatId" to chatId,
                  "trigger" to trigger,
                  "status" to res.code,
                ),
              )
              emitChangeLocked("chatPinnedUpdated", chatId, null)
              return@synchronized
            }

            val nextPins = parsePinnedEntriesFromBody(body, chatId)
            val previousPins = pinnedMessagesByChatId[chatId].orEmpty()
            val previousIds = previousPins.mapNotNull {
              normalized(it["messageId"] ?: it["message_id"])
            }.toSet()
            val nextIds = nextPins.mapNotNull {
              normalized(it["messageId"] ?: it["message_id"])
            }.toSet()
            previousIds.union(nextIds).forEach { messageId ->
              setMessagePinnedStateLocked(
                chatId = chatId,
                messageId = messageId,
                pinned = nextIds.contains(messageId),
              )
            }
            pinnedMessagesByChatId[chatId] = nextPins.toMutableList()
            state["updatedAt"] = System.currentTimeMillis()
            appendJournalLocked(
              "native-pinned-load-ok",
              mapOf(
                "chatId" to chatId,
                "trigger" to trigger,
                "count" to nextPins.size,
                "status" to res.code,
              ),
            )
            emitChangeLocked("chatPinnedUpdated", chatId, null)
          }
        }
      }
    })
  }

  private fun parsePinnedEntriesFromBody(body: String, chatId: String): List<Map<String, Any?>> {
    val parsed = parseJsonToMap(body)
    val data = parsed["data"] as? List<*> ?: return emptyList()
    return data.mapNotNull { raw ->
      val map =
        (raw as? Map<*, *>)?.entries?.associate { (key, value) -> key.toString() to value }
          ?: return@mapNotNull null
      normalizePinnedEntry(map, chatId, fallbackMessageId = null)
    }
  }

  private fun normalizePinnedEntry(
    raw: Map<String, Any?>,
    chatId: String,
    fallbackMessageId: String?,
  ): Map<String, Any?>? {
    val messageId = normalized(raw["messageId"] ?: raw["message_id"] ?: raw["id"] ?: fallbackMessageId)
      ?: return null
    val entry = linkedMapOf<String, Any?>(
      "messageId" to messageId,
      "chatId" to chatId,
      "pinnedAt" to (raw["pinnedAt"] ?: raw["pinned_at"] ?: System.currentTimeMillis()),
    )
    raw["timestamp"]?.let { entry["timestamp"] = it }
    normalized(raw["type"] ?: raw["messageType"] ?: raw["message_type"])?.let { entry["type"] = it }
    normalized(raw["mediaUrl"] ?: raw["media_url"])?.let { entry["mediaUrl"] = it }
    normalized(raw["fileName"] ?: raw["file_name"])?.let { entry["fileName"] = it }
    normalized(raw["text"] ?: raw["plainContent"] ?: raw["plain_content"])?.let { entry["text"] = it }
    return entry
  }

  private fun applyPinnedUpdateLocked(
    chatId: String,
    messageId: String,
    pinned: Boolean,
    payload: Map<String, Any?>,
    trigger: String,
    refreshRemote: Boolean,
  ) {
    setMessagePinnedStateLocked(chatId, messageId, pinned)

    val pins = pinnedMessagesByChatId.getOrPut(chatId) { mutableListOf() }
    pins.removeAll {
      normalized(it["messageId"] ?: it["message_id"]) == messageId
    }
    if (pinned) {
      val nextEntry =
        normalizePinnedEntry(payload, chatId, fallbackMessageId = messageId)
          ?: mapOf(
            "messageId" to messageId,
            "chatId" to chatId,
            "pinnedAt" to System.currentTimeMillis(),
          )
      pins.add(0, nextEntry)
    }
    state["updatedAt"] = System.currentTimeMillis()
    appendJournalLocked(
      "native-pinned-updated",
      mapOf(
        "chatId" to chatId,
        "messageId" to messageId,
        "pinned" to pinned,
        "trigger" to trigger,
      ),
    )
    if (refreshRemote) {
      fetchPinnedMessagesLocked(chatId, trigger)
    }
  }

  private fun setMessagePinnedStateLocked(chatId: String, messageId: String, pinned: Boolean) {
    liveMessageRowsByChat[chatId]?.let { perChat ->
      val row = perChat[messageId] ?: return@let
      val message = (row["message"] as? Map<*, *>)?.entries?.associate { (key, value) ->
        key.toString() to value
      }?.toMutableMap() ?: return@let
      message["isPinned"] = pinned
      message["pinned"] = pinned
      val updatedRow = row.toMutableMap()
      updatedRow["message"] = message
      perChat[messageId] = updatedRow
    }

    historyRowsByChat[chatId]?.let { rows ->
      var changed = false
      for (index in rows.indices) {
        val row = rows[index].toMutableMap()
        if (normalized(row["kind"]) != "message") continue
        val message =
          (row["message"] as? Map<*, *>)?.entries?.associate { (key, value) ->
            key.toString() to value
          }?.toMutableMap() ?: continue
        if (normalized(message["id"]) != messageId) continue
        message["isPinned"] = pinned
        message["pinned"] = pinned
        row["message"] = message
        rows[index] = row
        changed = true
      }
      if (changed) {
        historyRowsByChat[chatId] = rows
      }
    }
  }

  private fun statusSnapshotLocked(): Map<String, Any?> {
    val ctx = appContextRef
    val out = LinkedHashMap<String, Any?>(state)
    out["transportMode"] = transportModeLocked()
    out["activeBridgeId"] = normalized(getConfigValueLocked("activeBridgeId"))
    out["activePacketBridgeId"] = normalized(getConfigValueLocked("activePacketBridgeId"))
    out["bridgeBaseUrl"] = bridgeBaseUrlLocked()
    out["packetProxyPort"] = packetProxyPortLocked()
    out["packetStatus"] = normalized(getConfigValueLocked("packetStatus")) ?: state["state"]
    out["packetLastError"] = state["lastError"]
    out["bridgeReachable"] = if (transportModeLocked() == "bridge_text") state["connected"] == true else false
    out["disableCalls"] = disableCallsLocked()
    out["disableMedia"] = disableMediaLocked()
    out["disableRemoteAvatars"] = disableRemoteAvatarsLocked()
    out["onlineUserCount"] = onlineUsers.size
    out["onlineUserIds"] = onlineUsers.toList().sorted()
    out["lastSeenUserCount"] = lastSeenByUserId.size
    out["boundSurfaceCount"] = surfaceBindings.size
    out["boundChatCount"] = surfaceBindings.values.mapNotNull { it.chatId }.toSet().size
    out["openChatChannelCount"] = openChatChannels.size
    out["openChatChannels"] = LinkedHashMap(openChatChannels)
    out["receiptCount"] = receiptIndex.values.sumOf { it.size }
    out["localStatusCount"] = localStatusIndex.values.sumOf { it.size }
    out["nativeJoinedChatCount"] = nativeJoinedChatIds.size
    out["outboundDraftCount"] = pendingOutboundDraftsByMessageId.size
    out["outboundQueuedCount"] = pendingOutboundQueueByChat.values.sumOf { it.size }
    out["typingChatCount"] = peerTypingUserIdsByChatId.size
    out["typingUserCount"] = peerTypingUserIdsByChatId.values.sumOf { it.size }
    out["pinnedChatCount"] = pinnedMessagesByChatId.size
    out["pinnedMessageCount"] = pinnedMessagesByChatId.values.sumOf { it.size }
    out["journalCount"] = if (ctx != null) ChatEngineStore.getJournal(ctx).size else 0
    return out
  }

  private fun appendJournalLocked(event: String, payload: Map<String, Any?>) {
    val ctx = appContextRef
    if (ctx == null) {
      Log.d("ChatEngine", "journal skipped missingContext event=$event")
      return
    }
    val entry = linkedMapOf<String, Any?>(
      "event" to event,
      "timestamp" to System.currentTimeMillis(),
      "payload" to sanitizeJournalPayload(payload),
    )
    ChatEngineStore.appendJournal(ctx, entry)
  }

  /// Truncate sensitive identifiers in journal payloads to prevent
  /// leaking full chat/message/user IDs in plaintext storage.
  private fun sanitizeJournalPayload(payload: Map<String, Any?>): Map<String, Any?> {
    val sensitiveKeys = setOf("chatId", "messageId", "userId", "peerUserId", "fromId")
    val out = payload.toMutableMap()
    for (key in sensitiveKeys) {
      val value = out[key] as? String
      if (value != null && value.length > 8) {
        out[key] = value.take(8) + "..."
      }
    }
    return out
  }

  private fun emitChangeLocked(reason: String, chatId: String?, messageId: String?) {
    if (listeners.isEmpty()) return
    val callbacks = listeners.values.toList()
    callbacks.forEach { callback ->
      try {
        callback(reason, chatId, messageId)
      } catch (_: Throwable) {
      }
    }
  }

  private fun putNullableStateLocked(key: String, value: Any?) {
    if (value == null) {
      state.remove(key)
    } else {
      state[key] = value
    }
  }

  private fun normalized(value: Any?): String? {
    val raw = value?.toString()?.trim().orEmpty()
    return raw.ifEmpty { null }
  }

  private fun normalizedUpper(value: Any?): String? =
    normalized(value)?.uppercase()
}
