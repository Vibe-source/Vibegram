import Foundation
import SQLite3

/// Durable per-user message store backing ChatEngine's chat history.
///
/// Replaces the old UserDefaults JSON blob (120-row cap, full rewrite on every
/// store). Rows are upserted individually keyed by (user, chat, message id) so
/// the store can retain history far beyond the newest fetch window — the raw
/// material for real scroll-back pagination — while restores stay bounded.
///
/// ## Sealing (P3)
///
/// Message bodies are sealed at rest with AES-256-GCM under a per-install
/// Keychain key, through the Rust core's sealer. Two columns carry it:
/// `payload` holds the ciphertext and `seal_nonce` holds the nonce. A **NULL**
/// `seal_nonce` means the row predates sealing and `payload` is plaintext JSON.
///
/// The seal binds `(user_id, chat_id, message_id)` as associated data, so a row
/// copied to another address does not open. That is the difference between "the
/// bytes are encrypted" and "the bytes belong to this row", and it is what stops
/// a tampered or mis-restored database from rendering one chat's message inside
/// another.
///
/// Legacy plaintext rows are re-sealed as they are read, bounded by the read's
/// own limit — no unbounded migration pass, no separate schedule to get wrong.
///
/// When the Keychain refuses to hold a key the store keeps writing plaintext and
/// says so loudly. Sealing under something predictable would be worse than not
/// sealing at all, because every reader downstream would trust the column.
///
/// Threading: every call MUST come from ChatEngine's serial queue. The store
/// owns a single connection and does no locking of its own, and the sealer is
/// used only from that queue.
final class ChatMessageStore {

  private var db: OpaquePointer?

  /// `nil` when this device cannot custody a key — see the type comment. Built
  /// once; the Keychain lookup is not repeated per row.
  private let sealer: VibeStoreSealerHandle?

  /// Read/write tallies, surfaced through ``sealSummary`` so a diagnostics export
  /// can answer "is this database actually sealed" without a debugger.
  private(set) var sealedWrites = 0
  private(set) var plaintextWrites = 0
  private(set) var sealedReads = 0
  private(set) var legacyReads = 0
  private(set) var resealedRows = 0
  private(set) var sealFailures = 0
  private(set) var openFailures = 0

  /// Retained per chat after pruning; restores read far fewer (the engine's
  /// UI window). The surplus is deliberate headroom for future pagination.
  static let prunedChatRowLimit = 1000

  /// The production store, over the user's real message database.
  convenience init() {
    self.init(
      containerDirectory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
  }

  /// Designated initialiser, taking the directory that will hold `messages.db`.
  ///
  /// The parameter exists so tests can point at a temporary directory. Without
  /// it every test of this type runs against the real on-device database — the
  /// user's actual conversations — writing fixture rows into it and reading all
  /// of it back. A test that can corrupt the thing it is testing is not a test.
  init(containerDirectory: URL?) {
    // Built before the connection so a key failure is reported once, at open,
    // rather than discovered per row on the first write.
    sealer = VibeCoreBridge.makeSealer()
    if sealer == nil {
      VibeLog.error(
        "[ChatStore] sealing UNAVAILABLE — message bodies will be written in plaintext",
        category: "core")
    }
    guard let base = containerDirectory else { return }
    var dir = base.appendingPathComponent("VibeChatStore", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // The store and the key must share a lifetime, or sealing loses history.
    //
    // The seal key is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so it
    // does NOT travel in an encrypted backup. Application Support does. Restore
    // that pair onto a new phone and every sealed row is unopenable — the whole
    // local transcript, gone, with no way back. Excluding the database from
    // backup makes the two agree: a restored device starts with no local store
    // and refetches history from the server, which is the path that already
    // works. It also keeps message bodies out of iCloud, which is the posture we
    // want anyway.
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    try? dir.setResourceValues(resourceValues)

    let url = dir.appendingPathComponent("messages.db")
    var handle: OpaquePointer?
    guard sqlite3_open_v2(
      url.path, &handle,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
      let handle = handle
    else {
      NSLog("[ChatStore] open FAILED path=%@", url.path)
      if let orphan = handle { sqlite3_close_v2(orphan) }
      return
    }
    db = handle
    exec("PRAGMA journal_mode=WAL")
    exec("PRAGMA synchronous=NORMAL")
    exec("PRAGMA busy_timeout=2000")
    exec(
      """
      CREATE TABLE IF NOT EXISTS messages(
        user_id TEXT NOT NULL,
        chat_id TEXT NOT NULL,
        message_id TEXT NOT NULL,
        ts INTEGER NOT NULL,
        payload BLOB NOT NULL,
        PRIMARY KEY(user_id, chat_id, message_id)
      )
      """)
    exec(
      "CREATE INDEX IF NOT EXISTS idx_messages_chat_ts ON messages(user_id, chat_id, ts)")
    migrateSealColumn()
  }

  /// Adds `seal_nonce` to a table created before sealing existed.
  ///
  /// `ALTER TABLE` cannot be made idempotent in SQLite (no `IF NOT EXISTS` for a
  /// column), and letting it fail every launch would print a scary error for a
  /// non-event. So the column list is read first. Rows written before this point
  /// keep a NULL nonce and are read as plaintext until something re-seals them.
  private func migrateSealColumn() {
    guard let statement = prepare("PRAGMA table_info(messages)") else { return }
    defer { sqlite3_finalize(statement) }
    var hasSealNonce = false
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let nameBytes = sqlite3_column_text(statement, 1) else { continue }
      if String(cString: nameBytes) == "seal_nonce" {
        hasSealNonce = true
        break
      }
    }
    guard !hasSealNonce else { return }
    if exec("ALTER TABLE messages ADD COLUMN seal_nonce BLOB") {
      VibeLog.info("[ChatStore] added seal_nonce column — existing rows read as legacy plaintext",
        category: "core")
    }
  }

  deinit {
    if let db = db { sqlite3_close_v2(db) }
  }

  var isAvailable: Bool { db != nil }

  @discardableResult
  private func exec(_ sql: String) -> Bool {
    guard let db = db else { return false }
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
    if result != SQLITE_OK {
      NSLog(
        "[ChatStore] exec FAILED rc=%d error=%@ sql=%@",
        result, errorMessage.map { String(cString: $0) } ?? "?", String(sql.prefix(80)))
      sqlite3_free(errorMessage)
      return false
    }
    return true
  }

  private func prepare(_ sql: String) -> OpaquePointer? {
    guard let db = db else { return nil }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      NSLog("[ChatStore] prepare FAILED sql=%@", String(sql.prefix(80)))
      return nil
    }
    return statement
  }

  private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
    // SQLITE_TRANSIENT — sqlite copies the buffer before the Swift string is released.
    sqlite3_bind_text(
      statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
  }

  func upsertMessages(
    userId: String,
    chatId: String,
    entries: [(messageId: String, ts: Int64, payload: Data)]
  ) {
    guard db != nil, !userId.isEmpty, !chatId.isEmpty, !entries.isEmpty else { return }
    guard
      let statement = prepare(
        """
        INSERT INTO messages(user_id, chat_id, message_id, ts, payload, seal_nonce)
        VALUES(?, ?, ?, ?, ?, ?)
        ON CONFLICT(user_id, chat_id, message_id)
        DO UPDATE SET ts=excluded.ts, payload=excluded.payload, seal_nonce=excluded.seal_nonce
        """)
    else { return }
    defer { sqlite3_finalize(statement) }
    exec("BEGIN IMMEDIATE")
    for entry in entries {
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      bindText(statement, 1, userId)
      bindText(statement, 2, chatId)
      bindText(statement, 3, entry.messageId)
      sqlite3_bind_int64(statement, 4, entry.ts)

      // `seal_nonce` NULL is the ONLY signal that `payload` is plaintext, so the
      // two must be bound together or a reader will hand ciphertext to the JSON
      // parser (or worse, plaintext to the opener and drop a real message).
      let sealed = sealedBodyForWrite(
        userId: userId, chatId: chatId, messageId: entry.messageId, payload: entry.payload)
      bindBlob(statement, 5, sealed.body)
      if let nonce = sealed.nonce {
        bindBlob(statement, 6, nonce)
      } else {
        sqlite3_bind_null(statement, 6)
      }

      if sqlite3_step(statement) != SQLITE_DONE {
        NSLog("[ChatStore] upsert step FAILED chat=%@", String(chatId.prefix(12)))
      }
    }
    exec("COMMIT")

    // Sampled, so a device export can answer "is this store sealed" without
    // anyone having to reproduce anything — and without one line per write.
    upsertBatches += 1
    if upsertBatches % Self.summaryLogInterval == 1 {
      VibeLog.info("[ChatStore] \(sealSummary)", category: "core")
    }
  }

  private var upsertBatches = 0
  private static let summaryLogInterval = 20

  /// Seals one body, or falls back to plaintext when the device has no key.
  ///
  /// A seal failure on a device that *does* have a key is not a reason to write
  /// plaintext silently — that would quietly downgrade the whole store the first
  /// time the core hiccuped. It is counted and logged, and the row still goes to
  /// disk plaintext, because losing the user's message history is the worse
  /// outcome of the two.
  private func sealedBodyForWrite(
    userId: String, chatId: String, messageId: String, payload: Data
  ) -> (body: Data, nonce: Data?) {
    guard let sealer else {
      plaintextWrites += 1
      return (payload, nil)
    }
    do {
      let sealed = try sealer.seal(
        userId: userId, chatId: chatId, messageId: messageId, plaintext: payload)
      sealedWrites += 1
      return (sealed.sealedBody, sealed.sealNonce)
    } catch {
      sealFailures += 1
      plaintextWrites += 1
      // Identical lines fold in VibeLog's ring, so a systematic failure costs one
      // row with a count rather than one row per message.
      VibeLog.error(
        "[ChatStore] seal FAILED — writing plaintext", category: "core",
        metadata: ["error": String(describing: error)])
      return (payload, nil)
    }
  }

  private func bindBlob(_ statement: OpaquePointer, _ index: Int32, _ value: Data) {
    _ = value.withUnsafeBytes { buffer in
      sqlite3_bind_blob(
        statement, index, buffer.baseAddress, Int32(buffer.count),
        unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
  }

  func deleteMessages(userId: String, chatId: String, messageIds: [String]) {
    guard db != nil, !userId.isEmpty, !chatId.isEmpty, !messageIds.isEmpty else { return }
    guard
      let statement = prepare(
        "DELETE FROM messages WHERE user_id=? AND chat_id=? AND message_id=?")
    else { return }
    defer { sqlite3_finalize(statement) }
    exec("BEGIN IMMEDIATE")
    for messageId in messageIds {
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      bindText(statement, 1, userId)
      bindText(statement, 2, chatId)
      bindText(statement, 3, messageId)
      _ = sqlite3_step(statement)
    }
    exec("COMMIT")
  }

  /// Newest `limit` payloads in ascending timestamp order (transcript order).
  func recentMessagePayloads(userId: String, chatId: String, limit: Int) -> [Data] {
    guard db != nil, !userId.isEmpty, !chatId.isEmpty, limit > 0 else { return [] }
    guard
      let statement = prepare(
        """
        SELECT message_id, payload, seal_nonce FROM (
          SELECT message_id, payload, seal_nonce, ts FROM messages
          WHERE user_id=? AND chat_id=?
          ORDER BY ts DESC, message_id DESC LIMIT ?
        ) ORDER BY ts ASC, message_id ASC
        """)
    else { return [] }
    defer { sqlite3_finalize(statement) }
    bindText(statement, 1, userId)
    bindText(statement, 2, chatId)
    sqlite3_bind_int(statement, 3, Int32(limit))
    return openRows(statement, userId: userId, chatId: chatId)
  }

  /// Reads `(message_id, payload, seal_nonce)` rows and returns opened bodies.
  ///
  /// The whole point of one shared reader: every read path must agree on what a
  /// NULL nonce means and on what happens when a seal will not open. Two readers
  /// that disagree is how a chat ends up half-empty on one screen and full on
  /// another.
  ///
  /// A row that fails to open is **dropped**, not returned. Handing sealed bytes
  /// to `JSONSerialization` fails anyway, just silently and one layer further
  /// away from the cause.
  private func openRows(
    _ statement: OpaquePointer, userId: String, chatId: String
  ) -> [Data] {
    var payloads: [Data] = []
    var legacy: [(messageId: String, ts: Int64, payload: Data)] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let idBytes = sqlite3_column_text(statement, 0),
        let bodyBytes = sqlite3_column_blob(statement, 1)
      else { continue }
      let messageId = String(cString: idBytes)
      let body = Data(bytes: bodyBytes, count: Int(sqlite3_column_bytes(statement, 1)))

      guard sqlite3_column_type(statement, 2) != SQLITE_NULL,
        let nonceBytes = sqlite3_column_blob(statement, 2)
      else {
        // Written before sealing existed. Readable, and queued to be re-sealed
        // below so it stops being plaintext the first time anyone reads it.
        legacyReads += 1
        payloads.append(body)
        legacy.append((messageId, 0, body))
        continue
      }
      let nonce = Data(bytes: nonceBytes, count: Int(sqlite3_column_bytes(statement, 2)))
      guard let sealer else {
        // Sealed rows on disk and no key in the Keychain: the key was destroyed
        // (logout) or the Keychain item was lost. Nothing here can recover it.
        openFailures += 1
        VibeLog.error(
          "[ChatStore] sealed row unreadable — no key", category: "core",
          metadata: ["chat": String(chatId.prefix(12))])
        continue
      }
      do {
        payloads.append(
          try sealer.open(
            userId: userId, chatId: chatId, messageId: messageId,
            sealedBody: body, sealNonce: nonce))
        sealedReads += 1
      } catch {
        openFailures += 1
        VibeLog.error(
          "[ChatStore] seal OPEN failed — row dropped", category: "core",
          metadata: ["chat": String(chatId.prefix(12)), "error": String(describing: error)])
      }
    }
    if !legacy.isEmpty { resealLegacyRows(userId: userId, chatId: chatId, rows: legacy) }
    return payloads
  }

  /// Re-seals rows that were read as plaintext.
  ///
  /// Bounded by the caller's own read limit, which is why there is no separate
  /// migration job: the rows that get read are the rows that matter, and a chat
  /// nobody opens costs nothing. Timestamps are preserved by leaving `ts` alone —
  /// this updates the body columns only, so a re-seal can never reorder a
  /// transcript.
  private func resealLegacyRows(
    userId: String, chatId: String, rows: [(messageId: String, ts: Int64, payload: Data)]
  ) {
    guard let sealer, db != nil else { return }
    guard
      let statement = prepare(
        "UPDATE messages SET payload=?, seal_nonce=? WHERE user_id=? AND chat_id=? AND message_id=?"
      )
    else { return }
    defer { sqlite3_finalize(statement) }
    exec("BEGIN IMMEDIATE")
    var resealed = 0
    for row in rows {
      guard
        let sealed = try? sealer.seal(
          userId: userId, chatId: chatId, messageId: row.messageId, plaintext: row.payload)
      else {
        sealFailures += 1
        continue
      }
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      bindBlob(statement, 1, sealed.sealedBody)
      bindBlob(statement, 2, sealed.sealNonce)
      bindText(statement, 3, userId)
      bindText(statement, 4, chatId)
      bindText(statement, 5, row.messageId)
      if sqlite3_step(statement) == SQLITE_DONE { resealed += 1 }
    }
    exec("COMMIT")
    resealedRows += resealed
    if resealed > 0 {
      VibeLog.info(
        "[ChatStore] re-sealed legacy rows", category: "core",
        metadata: ["chat": String(chatId.prefix(12)), "rows": String(resealed)])
    }
  }

  #if DEBUG
    /// Writes a row the way this store did **before** sealing existed: cleartext
    /// `payload`, NULL `seal_nonce`.
    ///
    /// Test-only, and the only way to get an honest legacy row: every production
    /// write path now seals, so the upgrade case — a database full of rows from
    /// the previous build — is otherwise impossible to reproduce. Getting that
    /// case wrong means a user's history vanishes on update.
    @discardableResult
    func debugInsertLegacyPlaintextRow(
      userId: String, chatId: String, messageId: String, ts: Int64, payload: Data
    ) -> Bool {
      guard db != nil else { return false }
      guard
        let statement = prepare(
          """
          INSERT OR REPLACE INTO messages(user_id, chat_id, message_id, ts, payload, seal_nonce)
          VALUES(?, ?, ?, ?, ?, NULL)
          """)
      else { return false }
      defer { sqlite3_finalize(statement) }
      bindText(statement, 1, userId)
      bindText(statement, 2, chatId)
      bindText(statement, 3, messageId)
      sqlite3_bind_int64(statement, 4, ts)
      bindBlob(statement, 5, payload)
      return sqlite3_step(statement) == SQLITE_DONE
    }
  #endif

  /// One line an exported diagnostics log can be read for: is this database sealed.
  var sealSummary: String {
    let mode = sealer == nil ? "NO KEY (plaintext)" : "sealed"
    return
      "\(mode) · writes \(sealedWrites) sealed / \(plaintextWrites) plaintext · "
      + "reads \(sealedReads) sealed / \(legacyReads) legacy · "
      + "resealed \(resealedRows) · failures \(sealFailures) seal / \(openFailures) open"
  }

  /// Up to `limit` payloads below a transcript row, returned in ascending order.
  func olderMessagePayloads(
    userId: String,
    chatId: String,
    beforeTs: Int64,
    beforeMessageId: String,
    limit: Int
  ) -> [Data] {
    guard db != nil, !userId.isEmpty, !chatId.isEmpty, !beforeMessageId.isEmpty, limit > 0
    else { return [] }
    guard
      let statement = prepare(
        """
        SELECT message_id, payload, seal_nonce FROM (
          SELECT message_id, payload, seal_nonce, ts FROM messages
          WHERE user_id=? AND chat_id=?
            AND (ts < ? OR (ts = ? AND message_id < ?))
          ORDER BY ts DESC, message_id DESC LIMIT ?
        ) ORDER BY ts ASC, message_id ASC
        """)
    else { return [] }
    defer { sqlite3_finalize(statement) }
    bindText(statement, 1, userId)
    bindText(statement, 2, chatId)
    sqlite3_bind_int64(statement, 3, beforeTs)
    sqlite3_bind_int64(statement, 4, beforeTs)
    bindText(statement, 5, beforeMessageId)
    sqlite3_bind_int(statement, 6, Int32(limit))
    return openRows(statement, userId: userId, chatId: chatId)
  }

  func hasOlderMessages(
    userId: String,
    chatId: String,
    beforeTs: Int64,
    beforeMessageId: String
  ) -> Bool {
    guard db != nil, !userId.isEmpty, !chatId.isEmpty, !beforeMessageId.isEmpty else {
      return false
    }
    guard
      let statement = prepare(
        """
        SELECT 1 FROM messages
        WHERE user_id=? AND chat_id=?
          AND (ts < ? OR (ts = ? AND message_id < ?))
        LIMIT 1
        """)
    else { return false }
    defer { sqlite3_finalize(statement) }
    bindText(statement, 1, userId)
    bindText(statement, 2, chatId)
    sqlite3_bind_int64(statement, 3, beforeTs)
    sqlite3_bind_int64(statement, 4, beforeTs)
    bindText(statement, 5, beforeMessageId)
    return sqlite3_step(statement) == SQLITE_ROW
  }

  /// Every stored (message_id, ts) pair for one chat — the raw material for reconciling
  /// the store against a server-canonical transcript (ghost rows under retired ids are
  /// invisible to upserts and can only be found by enumerating what disk actually holds).
  func messageIdsWithTimestamps(userId: String, chatId: String) -> [(messageId: String, ts: Int64)] {
    guard db != nil, !userId.isEmpty, !chatId.isEmpty else { return [] }
    guard
      let statement = prepare(
        "SELECT message_id, ts FROM messages WHERE user_id=? AND chat_id=?")
    else { return [] }
    defer { sqlite3_finalize(statement) }
    bindText(statement, 1, userId)
    bindText(statement, 2, chatId)
    var results: [(messageId: String, ts: Int64)] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let idBytes = sqlite3_column_text(statement, 0) else { continue }
      results.append((String(cString: idBytes), sqlite3_column_int64(statement, 1)))
    }
    return results
  }

  func deleteChat(userId: String, chatId: String) {
    guard db != nil, !userId.isEmpty, !chatId.isEmpty else { return }
    guard let statement = prepare("DELETE FROM messages WHERE user_id=? AND chat_id=?") else {
      return
    }
    defer { sqlite3_finalize(statement) }
    bindText(statement, 1, userId)
    bindText(statement, 2, chatId)
    _ = sqlite3_step(statement)
  }

  /// Drop everything older than the newest `keepNewest` rows for one chat.
  func pruneChat(userId: String, chatId: String, keepNewest: Int = ChatMessageStore.prunedChatRowLimit) {
    guard db != nil, !userId.isEmpty, !chatId.isEmpty, keepNewest > 0 else { return }
    guard
      let statement = prepare(
        """
        DELETE FROM messages WHERE user_id=? AND chat_id=? AND message_id NOT IN (
          SELECT message_id FROM messages WHERE user_id=? AND chat_id=?
          ORDER BY ts DESC, message_id DESC LIMIT ?
        )
        """)
    else { return }
    defer { sqlite3_finalize(statement) }
    bindText(statement, 1, userId)
    bindText(statement, 2, chatId)
    bindText(statement, 3, userId)
    bindText(statement, 4, chatId)
    sqlite3_bind_int(statement, 5, Int32(keepNewest))
    _ = sqlite3_step(statement)
  }

  func messageCount(userId: String, chatId: String) -> Int {
    guard db != nil, !userId.isEmpty, !chatId.isEmpty else { return 0 }
    guard
      let statement = prepare(
        "SELECT COUNT(*) FROM messages WHERE user_id=? AND chat_id=?")
    else { return 0 }
    defer { sqlite3_finalize(statement) }
    bindText(statement, 1, userId)
    bindText(statement, 2, chatId)
    guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
    return Int(sqlite3_column_int(statement, 0))
  }
}
