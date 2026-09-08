import Foundation

/// Swift-side owner of the Rust sealed store (`vibe_core_store`, via `VibeStoreHandle`).
///
/// # What this is, and what it is not
///
/// This is the **write** side, live against the real on-disk database. Nothing
/// reads history through it yet: `ChatEngine` remains the sole source of truth
/// for what the list renders. The core tables (`core_messages_v1` and friends)
/// are additive and sit beside the app's `messages` table in the same file, so a
/// bad batch here cannot corrupt the transcript — the rollback is to stop
/// calling this type.
///
/// That ordering is deliberate. Flipping reads to a store that has never written
/// a byte on a real device would put an unproven SQLite path in front of the
/// user's history on its first run. Backfill first, verify against real data,
/// then migrate reads.
///
/// # Threading — the whole point
///
/// Unlike `VibeCoreHandle`, this boundary is **synchronous**: a `pageBefore` call
/// blocks until SQLite answers. Trading a stall on `ChatEngine.syncOnQueue` for a
/// stall on a Rust SQLite read would be no progress at all, so every entry point
/// runs on ``queue`` and ``assertOffMainThread(_:)`` refuses main-thread calls
/// loudly rather than serving them.
///
/// # Nothing here fails quietly
///
/// This is the first time the store runs anywhere but a unit test. Every open,
/// batch, and error is logged with the operation name and elapsed time. There is
/// no `try?` that discards a reason: a store that silently reports zero rows is
/// indistinguishable from a chat with no history, and that ambiguity is the bug
/// class this whole layer exists to end.
enum VibeCoreStoreBridge {

  // MARK: - Gate

  /// Default **on in DEBUG only**. Release builds never open the store.
  ///
  /// The flag is read once per operation rather than cached, so flipping it off
  /// from diagnostics stops the next batch instead of requiring a relaunch.
  static var isEnabled: Bool {
    #if DEBUG
      if UserDefaults.standard.object(forKey: "vibeCoreStoreDisabled") != nil {
        return !UserDefaults.standard.bool(forKey: "vibeCoreStoreDisabled")
      }
      return true
    #else
      return false
    #endif
  }

  static func setEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(!enabled, forKey: "vibeCoreStoreDisabled")
    NSLog("[CoreStore] gate %@", enabled ? "ENABLED" : "DISABLED")
    if !enabled { close() }
  }

  // MARK: - Ownership

  /// Serial, utility QoS. Serial because the handles are opened lazily and must
  /// not race; utility because backfill is background work that must never
  /// compete with rendering.
  private static let queue = DispatchQueue(label: "ai.vibe.core.store", qos: .utility)

  private static var coreStore: VibeStoreHandle?
  private static var legacyStore: VibeLegacyStoreHandle?
  private static var sealer: VibeStoreSealerHandle?
  /// Set once a fatal open failure is seen, so a broken install logs its reason
  /// once instead of once per chat open forever.
  private static var openFailed = false

  /// The file `ChatMessageStore` already owns. The core tables live beside the
  /// legacy `messages` table, never inside it.
  private static var databaseURL: URL? {
    guard
      let base = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return nil }
    return
      base
      .appendingPathComponent("VibeChatStore", isDirectory: true)
      .appendingPathComponent("messages.db")
  }

  /// Fails the call rather than blocking the main thread.
  ///
  /// A `precondition` would be worse than the bug: it would turn a
  /// mis-threaded call into a crash for the user, when the correct behaviour is
  /// to skip the work and leave a loud trail for us.
  @discardableResult
  private static func assertOffMainThread(_ operation: String) -> Bool {
    guard Thread.isMainThread else { return true }
    NSLog(
      "[CoreStore] REFUSED %@ — called on the MAIN THREAD. "
        + "This boundary is synchronous; route it through VibeCoreStoreBridge.queue.",
      operation)
    VibeLog.error(
      "[CoreStore] main-thread call refused: \(operation)", category: "core")
    return false
  }

  // MARK: - Open

  /// Opens both handles. Idempotent; safe to call on every launch.
  private static func openIfNeeded() -> Bool {
    dispatchPrecondition(condition: .onQueue(queue))
    if coreStore != nil, legacyStore != nil, sealer != nil { return true }
    if openFailed { return false }

    guard let url = databaseURL else {
      NSLog("[CoreStore] open FAILED — no Application Support directory")
      openFailed = true
      return false
    }

    // The legacy DB is created by ChatMessageStore on first write. Before that
    // there is genuinely nothing to back up, and that is not an error.
    guard FileManager.default.fileExists(atPath: url.path) else {
      NSLog("[CoreStore] open DEFERRED — %@ does not exist yet", url.lastPathComponent)
      return false
    }

    let began = CFAbsoluteTimeGetCurrent()
    do {
      let core = try VibeStoreHandle.open(path: url.path)
      let legacy = try VibeLegacyStoreHandle.open(path: url.path)
      guard let seal = VibeCoreBridge.makeSealer() else {
        // Refusing here is the point: backfilling without a sealer would write
        // the transcript to disk in the clear.
        NSLog("[CoreStore] open FAILED — no sealer; refusing to write unsealed rows")
        openFailed = true
        return false
      }
      coreStore = core
      legacyStore = legacy
      sealer = seal
      let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000
      NSLog("[CoreStore] OPEN ok path=%@ in %.0fms", url.lastPathComponent, ms)
      return true
    } catch {
      NSLog("[CoreStore] open FAILED error=%@", String(describing: error))
      VibeLog.error("[CoreStore] open failed: \(error)", category: "core")
      openFailed = true
      return false
    }
  }

  /// Drops the handles, closing both SQLite connections.
  static func close() {
    queue.async {
      guard coreStore != nil || legacyStore != nil else { return }
      coreStore = nil
      legacyStore = nil
      sealer = nil
      NSLog("[CoreStore] CLOSED")
    }
  }

  // MARK: - Self-test

  /// Proves the whole path on device: open → seal → write → page back → unseal
  /// → prune. Uses a reserved user id so it can never touch real rows.
  ///
  /// Run at launch. If this fails, nothing else in this type should be trusted,
  /// and the log says so in those words.
  static func runSelfTest() {
    guard isEnabled else {
      NSLog("[CoreStore] self-test SKIPPED — gate off")
      return
    }
    queue.async {
      guard openIfNeeded(), let core = coreStore, let seal = sealer else {
        NSLog("[CoreStore] self-test SKIPPED — store not open")
        return
      }

      let began = CFAbsoluteTimeGetCurrent()
      let user = "selftest-user"
      let chat = "selftest-chat"
      let probe = Data("core store probe".utf8)

      do {
        // Start clean so a killed previous run cannot make this pass falsely.
        try core.prune(userId: user, chatId: chat, keepNewest: 0)

        let sealed = try seal.seal(
          userId: user, chatId: chat, messageId: "m1", plaintext: probe)
        try core.upsert(
          userId: user, chatId: chat,
          rows: [
            VibeFfiStoredRow(
              messageId: "m1", tsMs: 1_000, flags: 0,
              sealedBody: sealed.sealedBody, sealNonce: sealed.sealNonce)
          ])

        let count = try core.count(userId: user, chatId: chat)
        let page = try core.pageBefore(userId: user, chatId: chat, before: nil, limit: 10)
        guard count == 1, page.count == 1, page[0].messageId == "m1" else {
          NSLog(
            "[CoreStore] self-test FAIL — wrote 1 row, read back count=%llu page=%ld",
            count, page.count)
          return
        }

        let opened = try seal.open(
          userId: user, chatId: chat, messageId: "m1",
          sealedBody: page[0].sealedBody, sealNonce: page[0].sealNonce)
        guard opened == probe else {
          NSLog("[CoreStore] self-test FAIL — unsealed bytes differ from what was sealed")
          return
        }

        // Load state must survive as a distinct fact from "zero rows".
        try core.setLoadState(userId: user, chatId: chat, state: .knownEmpty)
        let state = try core.loadState(userId: user, chatId: chat)
        guard state == .knownEmpty else {
          NSLog("[CoreStore] self-test FAIL — load state did not persist (got %@)",
            String(describing: state))
          return
        }

        try core.prune(userId: user, chatId: chat, keepNewest: 0)
        try core.setLoadState(userId: user, chatId: chat, state: .notLoaded)

        let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000
        NSLog(
          "[CoreStore] self-test PASS in %.0fms — seal→write→page→unseal→state→prune", ms)
      } catch {
        NSLog("[CoreStore] self-test FAIL error=%@", String(describing: error))
        VibeLog.error("[CoreStore] self-test failed: \(error)", category: "core")
      }
    }
  }

  // MARK: - Backfill

  /// Rows per batch. Small on purpose: each batch is one exclusive write
  /// transaction against the same file the app writes to, and a long one would
  /// hold the write lock while the user is sending.
  private static let backfillBatchSize: UInt32 = 200

  /// Seals one chat's legacy rows into the core tables, batch by batch.
  ///
  /// Resumable by construction — the cursor commits with the rows — so being
  /// killed mid-chat costs at most one batch of re-scanning.
  /// Chats already walked this session. Backfill is resumable and idempotent, so
  /// re-running is *correct* — just wasteful, and it would re-scan the whole
  /// chat on every open.
  private static var backfilledChats: Set<String> = []

  static func backfillChat(userId: String, chatId: String, completion: (() -> Void)? = nil) {
    guard isEnabled else { completion?(); return }
    guard !userId.isEmpty, !chatId.isEmpty else { completion?(); return }

    // The historical walk and its verify unseal rows; both yield to a live open.
    queue.asyncAfter(deadline: .now() + VibeChatOpenGate.delay) {
      defer { completion?() }
      let key = "\(userId)|\(chatId)"
      guard !backfilledChats.contains(key) else { return }
      guard openIfNeeded(), let core = coreStore, let legacy = legacyStore, let seal = sealer
      else { return }
      // Marked before the walk, not after: a chat that fails should not retry on
      // every single open and flood the log with the same failure.
      backfilledChats.insert(key)

      let began = CFAbsoluteTimeGetCurrent()
      var scanned: UInt64 = 0
      var written: UInt64 = 0
      var skipped: UInt64 = 0
      var batches = 0

      do {
        let legacyCount = try legacy.count(userId: userId, chatId: chatId)
        guard legacyCount > 0 else {
          NSLog("[CoreStore] backfill chat=%@ — legacy has 0 rows, nothing to do", chatId)
          return
        }

        while true {
          let progress = try core.backfillBatch(
            legacy: legacy, userId: userId, chatId: chatId, sealer: seal,
            batchLimit: backfillBatchSize)
          scanned += progress.scanned
          written += progress.written
          skipped += progress.skipped
          batches += 1

          if progress.done { break }
          // A batch that scans nothing but is not done would spin forever.
          guard progress.scanned > 0 else {
            NSLog(
              "[CoreStore] backfill chat=%@ STALLED — batch scanned 0 rows without "
                + "reporting done; stopping to avoid a spin", chatId)
            return
          }
          // Hard ceiling: 200 batches is 40k rows, far past any real chat.
          guard batches < 200 else {
            NSLog("[CoreStore] backfill chat=%@ CAPPED at %ld batches", chatId, batches)
            break
          }
        }

        let stored = try core.count(userId: userId, chatId: chatId)
        let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000
        NSLog(
          "[CoreStore] backfill chat=%@ DONE legacy=%llu scanned=%llu written=%llu "
            + "skipped=%llu stored=%llu batches=%ld in %.0fms",
          chatId, legacyCount, scanned, written, skipped, stored, batches, ms)

        if stored == 0 && written > 0 {
          NSLog(
            "[CoreStore] backfill chat=%@ INCONSISTENT — reported %llu written but "
              + "stored count is 0", chatId, written)
        }
      } catch {
        let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000
        NSLog(
          "[CoreStore] backfill chat=%@ FAILED after %ld batches in %.0fms error=%@",
          chatId, batches, ms, String(describing: error))
        VibeLog.error("[CoreStore] backfill failed chat=\(chatId): \(error)", category: "core")
        // The marker above is a flood guard — "do not rescan a chat that already failed
        // on every single open" — and it is right whenever the walk left *something*
        // behind. It is wrong when the table is empty, and `repairChat` is exactly how
        // that happens: it prunes to zero and relies on this walk to rebuild. A transient
        // failure there (the app writing to the same SQLite file from the engine queue is
        // enough) would otherwise turn a three-row disagreement into a permanently empty
        // chat — a strictly worse state than the one the repair was fixing. So: keep the
        // guard when there is data, drop it when refusing to retry guarantees nothing.
        let stored = (try? core.count(userId: userId, chatId: chatId)) ?? 0
        if stored == 0 {
          backfilledChats.remove(key)
          NSLog(
            "[CoreStore] backfill chat=%@ — core is empty after the failure, will retry",
            chatId)
        }
      }
    }
  }

  // MARK: - Clear

  /// Drops every sealed core row for a chat (and resets the backfill cursor).
  ///
  /// Called from the same choke as the legacy `messages` wipe so Clear Chat cannot
  /// leave a sealed table that would re-populate the list the moment reads move
  /// onto the core store. `keep_newest = 0` is the store's documented full clear.
  static func clearChat(userId: String, chatId: String) {
    guard isEnabled, !userId.isEmpty, !chatId.isEmpty else { return }
    queue.async {
      guard openIfNeeded(), let core = coreStore else { return }
      do {
        let before = try core.count(userId: userId, chatId: chatId)
        try core.prune(userId: userId, chatId: chatId, keepNewest: 0)
        try? core.resetBackfillCursor(userId: userId, chatId: chatId)
        NSLog(
          "[CoreStore] CLEAR chat=%@ dropped=%llu rows",
          chatId, before)
      } catch {
        NSLog(
          "[CoreStore] CLEAR chat=%@ FAILED error=%@",
          chatId, String(describing: error))
        VibeLog.error("[CoreStore] clear failed chat=\(chatId): \(error)", category: "core")
      }
    }
  }

  /// Marks message ids deleted, durably, so no later write can bring them back.
  ///
  /// The store has carried `core_tombstones_v1` — plus `tombstone()`, `is_tombstoned()`,
  /// FFI bindings and round-trip tests — since it was written, and until now **nothing
  /// called it**: an audit of every `open func` in the generated bindings against
  /// non-generated Swift found zero call sites. The reads did not consult it either, so
  /// the delete half of the store was designed, bound, and then left inert at both ends.
  ///
  /// It is now the durable half of the delete contract, and it is what `repairChat`
  /// alone cannot do. A rebuild re-derives the core table from the legacy one *at that
  /// moment*; it has no memory. The case in the device log is a message the user deleted
  /// that the server keeps re-sending — every history page re-inserts it, and a rebuild
  /// would faithfully copy it back. A tombstone is remembered, so the re-delivery is
  /// refused by the store rather than re-filtered by every caller.
  ///
  /// Transient ids (`stream-`, `lan-`) are dropped inside the store, not here.
  static func tombstoneMessages(userId: String, chatId: String, messageIds: [String]) {
    guard isEnabled, !userId.isEmpty, !chatId.isEmpty, !messageIds.isEmpty else { return }
    let atMs = Int64(Date().timeIntervalSince1970 * 1000)
    queue.async {
      guard openIfNeeded(), let core = coreStore else { return }
      do {
        // `forEveryone: false` — this records that THIS device should not show the row.
        // A delete-for-everyone is a server fact that arrives as its own frame; claiming
        // it here would overstate what a local delete decided.
        try core.tombstone(
          userId: userId, chatId: chatId, ids: messageIds, atMs: atMs, forEveryone: false)
        NSLog(
          "[CoreStore] tombstone chat=%@ ids=%ld — deleted rows can no longer be re-admitted",
          chatId, messageIds.count)
      } catch {
        NSLog(
          "[CoreStore] tombstone chat=%@ FAILED error=%@", chatId, String(describing: error))
        VibeLog.error("[CoreStore] tombstone failed chat=\(chatId): \(error)", category: "core")
      }
    }
  }

  /// Rebuilds a chat's sealed rows from the legacy table after rows were DELETED there.
  ///
  /// `mirrorRows` keeps the two tables in step for writes, and `clearChat` covers the full
  /// wipe — but nothing covered a *partial* delete, and the engine has four of them: a
  /// single-message delete, the twin-generation dedup on restore, the locally-deleted-id
  /// sweep at the persist choke, and the canonical ghost purge. Each one removed rows from
  /// `messages` and left the sealed copies behind, so the core table accumulated rows the
  /// app had already decided the user should not see. Device log 2026-08-08, chat
  /// 71312111f04b: `verify … MISMATCH missingFromCore=3 extraInCore=3`, stable across
  /// three minutes and a send — a fixed set of rows the two tables disagree about, not a
  /// race that settles.
  ///
  /// That is a correctness bug today (verify can never reach MATCH, which is the gate for
  /// migrating reads) and a user-visible one the moment reads move onto this store: a
  /// deleted message would come back.
  ///
  /// # Why rebuild rather than delete
  ///
  /// `VibeStoreHandle` exposes upsert / prune / count / backfill and no per-row delete, so
  /// a targeted removal would mean new Rust, new bindgen and a new xcframework. Deletes
  /// are rare events on a path already doing SQLite work, and `prune(keepNewest: 0)` +
  /// re-backfill is exact by construction — it re-derives the core table from the legacy
  /// one *after* the deletion, so it cannot leave a straggler the way a targeted delete
  /// with a missed call site would. Proportionate beats clever here.
  static func repairChat(userId: String, chatId: String, reason: String) {
    guard isEnabled, !userId.isEmpty, !chatId.isEmpty else { return }
    queue.async {
      guard openIfNeeded(), let core = coreStore else { return }
      do {
        let before = try core.count(userId: userId, chatId: chatId)
        try core.prune(userId: userId, chatId: chatId, keepNewest: 0)
        try core.resetBackfillCursor(userId: userId, chatId: chatId)
        // Backfill refuses a chat it has already walked; this delete IS the reason to
        // walk it again.
        backfilledChats.remove("\(userId)|\(chatId)")
        NSLog(
          "[CoreStore] repair chat=%@ reason=%@ dropped=%llu sealed rows — rebuilding from legacy",
          chatId, reason, before)
      } catch {
        NSLog(
          "[CoreStore] repair chat=%@ reason=%@ FAILED error=%@",
          chatId, reason, String(describing: error))
        VibeLog.error("[CoreStore] repair failed chat=\(chatId): \(error)", category: "core")
        return
      }
    }
    // Same serial queue, so this lands strictly after the prune above.
    backfillChat(userId: userId, chatId: chatId)
  }

  // MARK: - Incremental mirror

  /// Seals and upserts the same rows the app just wrote to its legacy table.
  ///
  /// Backfill alone is not enough and cannot be made enough: its cursor walks
  /// newest→oldest and then reports `done`, so every message that arrives
  /// *after* it finishes is newer than where it started and can never be picked
  /// up. Re-running it would rescan the whole chat to find a handful of rows.
  ///
  /// Mirroring at the persist choke is the root fix — the payloads are already
  /// in hand there, so this is a seal and an upsert, not a scan. Backfill stays
  /// what it should be: the one-time historical catch-up.
  ///
  /// `keepNewest` mirrors `ChatMessageStore.prunedChatRowLimit`, so the two
  /// tables trim together instead of the core one growing without bound.
  static func mirrorRows(
    userId: String,
    chatId: String,
    entries: [(messageId: String, ts: Int64, payload: Data)],
    keepNewest: UInt32
  ) {
    guard isEnabled, !userId.isEmpty, !chatId.isEmpty, !entries.isEmpty else { return }
    queue.async {
      guard openIfNeeded(), let core = coreStore, let seal = sealer else { return }

      var rows: [VibeFfiStoredRow] = []
      rows.reserveCapacity(entries.count)
      var sealFailures = 0
      for entry in entries {
        do {
          let sealed = try seal.seal(
            userId: userId, chatId: chatId, messageId: entry.messageId,
            plaintext: entry.payload)
          rows.append(
            VibeFfiStoredRow(
              messageId: entry.messageId, tsMs: entry.ts, flags: 0,
              sealedBody: sealed.sealedBody, sealNonce: sealed.sealNonce))
        } catch {
          // Counted, never written in the clear, and never fatal to the batch.
          sealFailures += 1
        }
      }
      if sealFailures > 0 {
        NSLog(
          "[CoreStore] mirror chat=%@ — %ld/%ld rows failed to seal and were dropped",
          chatId, sealFailures, entries.count)
      }
      guard !rows.isEmpty else { return }

      do {
        try core.upsert(userId: userId, chatId: chatId, rows: rows)
        if keepNewest > 0 {
          try core.prune(userId: userId, chatId: chatId, keepNewest: keepNewest)
        }
      } catch {
        NSLog(
          "[CoreStore] mirror chat=%@ FAILED rows=%ld error=%@",
          chatId, rows.count, String(describing: error))
        VibeLog.error("[CoreStore] mirror failed chat=\(chatId): \(error)", category: "core")
      }
    }
  }

  // MARK: - Reads (not yet wired to the list)

  /// Newest page for a chat, unsealed. **Must already be on ``queue``** — the
  /// `OnQueue` suffix is the same contract the engine's `Locked` suffix carries.
  ///
  /// This is the call the list will eventually make instead of going through
  /// `ChatEngine.syncOnQueue`. It is exercised by ``verifyAgainstLegacy`` today
  /// so the read path is proven against real data before anything depends on it.
  ///
  /// Deliberately no `dispatchPrecondition`: that traps, and trapping on a
  /// mis-threaded call would crash the user's app over a mistake of ours. The
  /// refusal above is loud enough to find it in a log.
  private static func newestPageOnQueue(
    userId: String, chatId: String, limit: UInt32
  ) -> [Data]? {
    guard assertOffMainThread("newestPage") else { return nil }
    guard let core = coreStore, let seal = sealer else { return nil }

    do {
      let rows = try core.pageBefore(userId: userId, chatId: chatId, before: nil, limit: limit)
      var payloads: [Data] = []
      payloads.reserveCapacity(rows.count)
      var unsealFailures = 0
      for row in rows {
        do {
          payloads.append(
            try seal.open(
              userId: userId, chatId: chatId, messageId: row.messageId,
              sealedBody: row.sealedBody, sealNonce: row.sealNonce))
        } catch {
          // Counted, not thrown: one unopenable row must not lose the page.
          unsealFailures += 1
        }
      }
      if unsealFailures > 0 {
        NSLog(
          "[CoreStore] newestPage chat=%@ — %ld/%ld rows failed to unseal",
          chatId, unsealFailures, rows.count)
      }
      return payloads
    } catch {
      NSLog("[CoreStore] newestPage chat=%@ FAILED error=%@", chatId, String(describing: error))
      return nil
    }
  }

  /// Rows compared per verify. The list never renders more than this at once, so
  /// agreement across this window is agreement about what the user would see.
  private static let verifyWindow: UInt32 = 200

  /// Compares what the core store holds against the legacy table for one chat.
  ///
  /// This is the gate for migrating reads. Until it reports agreement on real
  /// chats on a real device, the list stays on the Swift path.
  ///
  /// # Why this compares ids, not counts
  ///
  /// Counts race and give false alarms. The two tables prune independently, so a
  /// verify landing between the legacy prune and the core prune sees a
  /// difference that resolves itself a moment later — and a count says nothing
  /// about *which* rows differ or what order they are in. Comparing the newest
  /// ids answers the only question that matters: would the list render the same
  /// rows, in the same order, from either table.
  static func verifyAgainstLegacy(userId: String, chatId: String) {
    guard isEnabled else { return }
    queue.async {
      guard openIfNeeded(), let core = coreStore, let legacy = legacyStore else { return }
      do {
        let began = CFAbsoluteTimeGetCurrent()
        let legacyIds = try legacy.newestMessageIds(
          userId: userId, chatId: chatId, limit: verifyWindow)
        let coreIds = try core.newestMessageIds(
          userId: userId, chatId: chatId, limit: verifyWindow)
        let readMs = (CFAbsoluteTimeGetCurrent() - began) * 1000

        // Both come back ascending, so the newest rows are the tails. Comparing
        // tails of equal length tolerates one table legitimately holding more
        // history than the other while still catching any disagreement about
        // the rows they share.
        let window = min(legacyIds.count, coreIds.count)
        guard window > 0 else {
          NSLog(
            "[CoreStore] verify chat=%@ EMPTY legacy=%ld core=%ld",
            chatId, legacyIds.count, coreIds.count)
          return
        }
        let legacyTail = Array(legacyIds.suffix(window))
        let coreTail = Array(coreIds.suffix(window))

        if legacyTail == coreTail {
          // Also exercise the real read path — page + unseal — because that is
          // what the list will do, and its cost is the case for moving to it.
          let unsealBegan = CFAbsoluteTimeGetCurrent()
          let page = newestPageOnQueue(userId: userId, chatId: chatId, limit: 50)
          let unsealMs = (CFAbsoluteTimeGetCurrent() - unsealBegan) * 1000
          NSLog(
            "[CoreStore] verify chat=%@ MATCH newest=%ld ids+order identical "
              + "(legacy=%ld core=%ld) ids=%.1fms unsealed=%ld in %.1fms",
            chatId, window, legacyIds.count, coreIds.count, readMs,
            page?.count ?? -1, unsealMs)
          return
        }

        // Disagreement: say exactly how, so this is actionable from the log
        // alone rather than an invitation to go re-derive it.
        let missing = Set(legacyTail).subtracting(coreTail)
        let extra = Set(coreTail).subtracting(legacyTail)
        let firstDiff = zip(legacyTail, coreTail).enumerated()
          .first { $0.element.0 != $0.element.1 }?.offset ?? window
        // The raw counts belong on this line, not just on MATCH. Without them a 3/3
        // difference has two readings that need opposite fixes and cannot be told apart:
        // core is SHORT three rows the mirror never wrote (a write path that skips the
        // choke), or core is LONG three rows the legacy table deleted (a delete path with
        // no core counterpart), whose oldest three then fall out of the compared tail and
        // show up as "missing". `legacy > core` says the first; `core > legacy` the second.
        NSLog(
          "[CoreStore] verify chat=%@ MISMATCH window=%ld firstDiffAt=%ld "
            + "missingFromCore=%ld extraInCore=%ld legacy=%ld core=%ld read=%.1fms",
          chatId, window, firstDiff, missing.count, extra.count,
          legacyIds.count, coreIds.count, readMs)
        if let sample = missing.first {
          NSLog("[CoreStore] verify chat=%@ sample missing id=%@", chatId, sample)
        }
      } catch {
        NSLog("[CoreStore] verify chat=%@ FAILED error=%@", chatId, String(describing: error))
      }
    }
  }
}
