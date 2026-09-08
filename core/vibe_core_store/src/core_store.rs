//! Read-write sealed message store (`core_messages_v1` and related tables).
//!
//! Additive and independent of the legacy `messages` table. This module never
//! reads or writes `messages` — that table remains the app's rollback surface.
//!
//! `sealed_body` and `seal_nonce` are opaque. This crate never seals, opens,
//! parses, or logs their contents. Backfill hands legacy payloads to a caller
//! sealer and persists only the returned opaque bytes.

use std::path::Path;
use std::time::Duration;

use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};

use crate::error::{map_open_error, map_query_error, VibeStoreError};
use crate::store::{VibeLegacyStore, VibeStoreCursor, VibeStoredRow, MAX_PAGE_LIMIT};

// ---------------------------------------------------------------------------
// Backfill API (loop + resumability only — sealing is the caller's job)
// ---------------------------------------------------------------------------

/// Supplied by the caller. You call it; you never implement it.
pub trait VibeRowSealer {
    /// Returns `(sealed_body, seal_nonce)` for one legacy payload, or `None` if
    /// this row must be skipped (never sealed, never persisted).
    fn seal(
        &self,
        user_id: &str,
        chat_id: &str,
        message_id: &str,
        payload: &[u8],
    ) -> Option<(Vec<u8>, Vec<u8>)>;
}

/// Counts for one [`VibeCoreStore::backfill_batch`] call (not cumulative).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VibeBackfillProgress {
    pub scanned: u64,
    pub written: u64,
    pub skipped: u64,
    pub done: bool,
}

/// Meta value first-byte tags for the backfill resume cursor.
const BF_META_CURSOR: u8 = 0;
const BF_META_DONE: u8 = 1;

/// Busy-timeout matching `ChatMessageStore` (`PRAGMA busy_timeout=2000`).
const BUSY_TIMEOUT: Duration = Duration::from_millis(2000);

/// One sealed row. Body and nonce are opaque ciphertext — never inspected here.
#[derive(Clone, PartialEq, Eq)]
pub struct VibeSealedRow {
    pub message_id: String,
    pub ts_ms: i64,
    pub flags: i64,
    pub sealed_body: Vec<u8>,
    pub seal_nonce: Vec<u8>,
}

impl std::fmt::Debug for VibeSealedRow {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Lengths only — sealed bytes must not appear in diagnostics.
        f.debug_struct("VibeSealedRow")
            .field("message_id", &self.message_id)
            .field("ts_ms", &self.ts_ms)
            .field("flags", &self.flags)
            .field("sealed_body_len", &self.sealed_body.len())
            .field("seal_nonce_len", &self.seal_nonce.len())
            .finish()
    }
}

/// Distinct from "not loaded". Never model a known-empty chat as an empty `Vec`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum VibeChatLoadState {
    /// No durable load decision has been recorded for this chat.
    NotLoaded,
    /// The chat was loaded and is known to contain no durable rows.
    KnownEmpty,
    /// The chat has been loaded (and may have zero or more durable rows).
    Loaded,
}

/// Read-write handle onto the sealed core tables.
///
/// Owns its own connection. Opened read-write; creates the additive schema on
/// first open. Never touches the legacy `messages` table.
pub struct VibeCoreStore {
    conn: Connection,
}

impl std::fmt::Debug for VibeCoreStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("VibeCoreStore")
    }
}

impl VibeCoreStore {
    /// Open (or create) the database file and ensure the additive schema exists.
    ///
    /// Applies `journal_mode=WAL`, `synchronous=NORMAL`, `busy_timeout=2000`
    /// to match the app (`ChatMessageStore`).
    pub fn open(path: &Path) -> Result<Self, VibeStoreError> {
        let conn = Connection::open(path).map_err(|e| map_open_error(&e))?;

        conn.busy_timeout(BUSY_TIMEOUT)
            .map_err(|e| map_open_error(&e))?;

        // Match ChatMessageStore pragmas exactly. journal_mode returns a row;
        // execute_batch is fine for the rest.
        conn.pragma_update(None, "journal_mode", "WAL")
            .map_err(|e| map_open_error(&e))?;
        conn.pragma_update(None, "synchronous", "NORMAL")
            .map_err(|e| map_open_error(&e))?;

        conn.execute_batch(
            r"
            CREATE TABLE IF NOT EXISTS core_messages_v1(
              user_id     TEXT NOT NULL,
              chat_id     TEXT NOT NULL,
              message_id  TEXT NOT NULL,
              ts          INTEGER NOT NULL,
              order_key   BLOB NOT NULL,
              flags       INTEGER NOT NULL,
              sealed_body BLOB NOT NULL,
              seal_nonce  BLOB NOT NULL,
              PRIMARY KEY(user_id, chat_id, message_id)
            );
            CREATE INDEX IF NOT EXISTS idx_core_messages_order
              ON core_messages_v1(user_id, chat_id, ts, message_id);

            CREATE TABLE IF NOT EXISTS core_tombstones_v1(
              user_id TEXT NOT NULL,
              chat_id TEXT NOT NULL,
              message_id TEXT NOT NULL,
              at_ms INTEGER NOT NULL,
              for_everyone INTEGER NOT NULL,
              PRIMARY KEY(user_id, chat_id, message_id)
            );

            CREATE TABLE IF NOT EXISTS core_meta_v1(
              k TEXT PRIMARY KEY,
              v BLOB NOT NULL
            );
            ",
        )
        .map_err(|e| map_open_error(&e))?;

        Ok(Self { conn })
    }

    /// Insert or replace sealed rows in a single `BEGIN IMMEDIATE` transaction.
    ///
    /// - Transient ids (`stream-`, `lan-`, `bridge-` prefixes) are skipped.
    /// - Safe to kill mid-batch and re-run: half-written batches leave no
    ///   partial commit; re-running the same batch is idempotent.
    pub fn upsert(
        &self,
        user_id: &str,
        chat_id: &str,
        rows: &[VibeSealedRow],
    ) -> Result<(), VibeStoreError> {
        // BEGIN IMMEDIATE — exclusive write lock for the whole batch so a
        // kill mid-batch rolls back cleanly and a re-run is a pure upsert.
        let tx = Transaction::new_unchecked(&self.conn, TransactionBehavior::Immediate)
            .map_err(|e| map_query_error(&e))?;

        {
            let mut stmt = tx
                .prepare(
                    r"
                    -- A tombstoned id is never re-admitted, on either write path.
                    --
                    -- This is the difference between a delete that holds and one that
                    -- has to be re-applied forever: the server keeps re-sending a
                    -- message the user deleted locally, and a plain upsert re-inserts
                    -- it on every history page — while the backfill walk would drag it
                    -- back out of the legacy table on the next rebuild. The tombstone is
                    -- the durable memory of the decision, so the refusal belongs in the
                    -- store rather than in a filter each caller has to remember.
                    INSERT INTO core_messages_v1(
                      user_id, chat_id, message_id, ts, order_key,
                      flags, sealed_body, seal_nonce
                    )
                    SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8
                    WHERE NOT EXISTS (
                      SELECT 1 FROM core_tombstones_v1
                      WHERE user_id = ?1 AND chat_id = ?2 AND message_id = ?3
                    )
                    ON CONFLICT(user_id, chat_id, message_id) DO UPDATE SET
                      ts = excluded.ts,
                      order_key = excluded.order_key,
                      flags = excluded.flags,
                      sealed_body = excluded.sealed_body,
                      seal_nonce = excluded.seal_nonce
                    ",
                )
                .map_err(|e| map_query_error(&e))?;

            for row in rows {
                if is_transient_id(&row.message_id) {
                    continue;
                }
                let order_key = pack_order_key(row.ts_ms, &row.message_id);
                stmt.execute(params![
                    user_id,
                    chat_id,
                    row.message_id,
                    row.ts_ms,
                    order_key,
                    row.flags,
                    row.sealed_body,
                    row.seal_nonce,
                ])
                .map_err(|e| map_query_error(&e))?;
            }
        }

        tx.commit().map_err(|e| map_query_error(&e))?;
        Ok(())
    }

    /// Rows immediately preceding `before` in the total order, ascending.
    ///
    /// - `before = None` → newest page (the tail of the chat).
    /// - `limit` is clamped to [`MAX_PAGE_LIMIT`]. A zero limit yields an empty vec.
    pub fn page_before(
        &self,
        user_id: &str,
        chat_id: &str,
        before: Option<VibeStoreCursor>,
        limit: u32,
    ) -> Result<Vec<VibeSealedRow>, VibeStoreError> {
        let limit = clamp_limit(limit);
        if limit == 0 {
            return Ok(Vec::new());
        }

        match before {
            None => self.query_rows(
                r"
                SELECT message_id, ts, flags, sealed_body, seal_nonce FROM (
                  SELECT m.message_id, m.ts, m.flags, m.sealed_body, m.seal_nonce
                  FROM core_messages_v1 m
                  WHERE m.user_id = ?1 AND m.chat_id = ?2
                    AND NOT EXISTS (
                      SELECT 1 FROM core_tombstones_v1 t
                      WHERE t.user_id = m.user_id AND t.chat_id = m.chat_id
                        AND t.message_id = m.message_id
                    )
                  ORDER BY m.ts DESC, m.message_id DESC
                  LIMIT ?3
                )
                ORDER BY ts ASC, message_id ASC
                ",
                params![user_id, chat_id, limit],
            ),
            Some(cursor) => self.query_rows(
                r"
                SELECT message_id, ts, flags, sealed_body, seal_nonce FROM (
                  SELECT m.message_id, m.ts, m.flags, m.sealed_body, m.seal_nonce
                  FROM core_messages_v1 m
                  WHERE m.user_id = ?1 AND m.chat_id = ?2
                    AND (m.ts < ?3 OR (m.ts = ?3 AND m.message_id < ?4))
                    AND NOT EXISTS (
                      SELECT 1 FROM core_tombstones_v1 t
                      WHERE t.user_id = m.user_id AND t.chat_id = m.chat_id
                        AND t.message_id = m.message_id
                    )
                  ORDER BY m.ts DESC, m.message_id DESC
                  LIMIT ?5
                )
                ORDER BY ts ASC, message_id ASC
                ",
                params![user_id, chat_id, cursor.ts_ms, cursor.message_id, limit],
            ),
        }
    }

    /// Rows immediately following `after` in the total order, ascending.
    ///
    /// - `after = None` → oldest page (the head of the chat).
    /// - `limit` is clamped to [`MAX_PAGE_LIMIT`]. A zero limit yields an empty vec.
    pub fn page_after(
        &self,
        user_id: &str,
        chat_id: &str,
        after: Option<VibeStoreCursor>,
        limit: u32,
    ) -> Result<Vec<VibeSealedRow>, VibeStoreError> {
        let limit = clamp_limit(limit);
        if limit == 0 {
            return Ok(Vec::new());
        }

        match after {
            None => self.query_rows(
                r"
                SELECT m.message_id, m.ts, m.flags, m.sealed_body, m.seal_nonce
                FROM core_messages_v1 m
                WHERE m.user_id = ?1 AND m.chat_id = ?2
                  AND NOT EXISTS (
                    SELECT 1 FROM core_tombstones_v1 t
                    WHERE t.user_id = m.user_id AND t.chat_id = m.chat_id
                      AND t.message_id = m.message_id
                  )
                ORDER BY m.ts ASC, m.message_id ASC
                LIMIT ?3
                ",
                params![user_id, chat_id, limit],
            ),
            Some(cursor) => self.query_rows(
                r"
                SELECT m.message_id, m.ts, m.flags, m.sealed_body, m.seal_nonce
                FROM core_messages_v1 m
                WHERE m.user_id = ?1 AND m.chat_id = ?2
                  AND (m.ts > ?3 OR (m.ts = ?3 AND m.message_id > ?4))
                  AND NOT EXISTS (
                    SELECT 1 FROM core_tombstones_v1 t
                    WHERE t.user_id = m.user_id AND t.chat_id = m.chat_id
                      AND t.message_id = m.message_id
                  )
                ORDER BY m.ts ASC, m.message_id ASC
                LIMIT ?5
                ",
                params![user_id, chat_id, cursor.ts_ms, cursor.message_id, limit],
            ),
        }
    }

    /// Record tombstones for the given message ids (upsert by primary key).
    pub fn tombstone(
        &self,
        user_id: &str,
        chat_id: &str,
        ids: &[&str],
        at_ms: i64,
        for_everyone: bool,
    ) -> Result<(), VibeStoreError> {
        let tx = Transaction::new_unchecked(&self.conn, TransactionBehavior::Immediate)
            .map_err(|e| map_query_error(&e))?;

        {
            let mut stmt = tx
                .prepare(
                    r"
                    INSERT INTO core_tombstones_v1(
                      user_id, chat_id, message_id, at_ms, for_everyone
                    ) VALUES (?1, ?2, ?3, ?4, ?5)
                    ON CONFLICT(user_id, chat_id, message_id) DO UPDATE SET
                      at_ms = excluded.at_ms,
                      for_everyone = excluded.for_everyone
                    ",
                )
                .map_err(|e| map_query_error(&e))?;

            let fe: i64 = i64::from(for_everyone);
            for id in ids {
                if is_transient_id(id) {
                    continue;
                }
                stmt.execute(params![user_id, chat_id, id, at_ms, fe])
                    .map_err(|e| map_query_error(&e))?;
            }
        }

        tx.commit().map_err(|e| map_query_error(&e))?;
        Ok(())
    }

    /// Whether `(user_id, chat_id, message_id)` has a tombstone row.
    pub fn is_tombstoned(
        &self,
        user_id: &str,
        chat_id: &str,
        message_id: &str,
    ) -> Result<bool, VibeStoreError> {
        let n: i64 = self
            .conn
            .query_row(
                r"
                SELECT COUNT(*) FROM core_tombstones_v1
                WHERE user_id = ?1 AND chat_id = ?2 AND message_id = ?3
                ",
                params![user_id, chat_id, message_id],
                |row| row.get(0),
            )
            .map_err(|e| map_query_error(&e))?;
        Ok(n > 0)
    }

    /// Keep the newest `keep_newest` rows for the chat; delete older ones.
    ///
    /// Newest is defined by the total order `(ts ASC, message_id ASC)` — the
    /// rows that sort last. A zero keep deletes all rows for the chat.
    pub fn prune(
        &self,
        user_id: &str,
        chat_id: &str,
        keep_newest: u32,
    ) -> Result<(), VibeStoreError> {
        // Prune never touches tombstones, and the reason is the opposite of the
        // intuitive one.
        //
        // "A tombstone whose row is gone is dead weight" is exactly backwards: a
        // tombstone for an ABSENT row is the load-bearing case. Its entire job is to
        // refuse re-admission of a row that is not there. The one next to a present row
        // is the transitional state.
        //
        // Concretely, this is the flow at every delete site: tombstone the id, then
        // `VibeCoreStoreBridge.repairChat`, which is `prune(keep_newest: 0)` plus a
        // re-backfill. A prune that cleared tombstones would destroy the guard two calls
        // after it was set, and the next server re-delivery of that message would find
        // nothing to refuse it — the delete would have to be re-applied forever, which is
        // the exact failure the tombstone exists to end. Pinned by
        // `a_tombstone_survives_prune_and_still_refuses_re_delivery`.
        //
        // Unbounded growth is the right thing to worry about, but the bound belongs on
        // age (`at_ms`), never on row presence.
        if keep_newest == 0 {
            self.conn
                .execute(
                    "DELETE FROM core_messages_v1 WHERE user_id = ?1 AND chat_id = ?2",
                    params![user_id, chat_id],
                )
                .map_err(|e| map_query_error(&e))?;
            return Ok(());
        }

        // Delete everything that is not among the newest `keep_newest` rows.
        //
        // The newest-N subquery deliberately does NOT exclude tombstoned rows: prune is
        // about physical storage, and a tombstoned row still occupies a slot. Filtering
        // it here would let masked rows push live ones out of the retained window.
        self.conn
            .execute(
                r"
                DELETE FROM core_messages_v1
                WHERE user_id = ?1 AND chat_id = ?2
                  AND message_id NOT IN (
                    SELECT message_id FROM core_messages_v1
                    WHERE user_id = ?1 AND chat_id = ?2
                    ORDER BY ts DESC, message_id DESC
                    LIMIT ?3
                  )
                ",
                params![user_id, chat_id, keep_newest],
            )
            .map_err(|e| map_query_error(&e))?;
        Ok(())
    }

    /// Number of sealed rows for `(user_id, chat_id)`.
    pub fn count(&self, user_id: &str, chat_id: &str) -> Result<u64, VibeStoreError> {
        let n: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM core_messages_v1 WHERE user_id = ?1 AND chat_id = ?2",
                params![user_id, chat_id],
                |row| row.get(0),
            )
            .map_err(|e| map_query_error(&e))?;
        Ok(u64::try_from(n).unwrap_or(0))
    }

    /// Persisted load state for a chat. Missing meta → [`VibeChatLoadState::NotLoaded`].
    pub fn load_state(
        &self,
        user_id: &str,
        chat_id: &str,
    ) -> Result<VibeChatLoadState, VibeStoreError> {
        let key = load_state_key(user_id, chat_id);
        let value: Option<Vec<u8>> = self
            .conn
            .query_row(
                "SELECT v FROM core_meta_v1 WHERE k = ?1",
                params![key],
                |row| row.get(0),
            )
            .optional()
            .map_err(|e| map_query_error(&e))?;

        match value.as_deref() {
            Some(b"1") => Ok(VibeChatLoadState::KnownEmpty),
            Some(b"2") => Ok(VibeChatLoadState::Loaded),
            // Missing or unknown encoding → not loaded (safe default).
            _ => Ok(VibeChatLoadState::NotLoaded),
        }
    }

    /// Persist the three-state load decision. `NotLoaded` clears the meta key.
    pub fn set_load_state(
        &self,
        user_id: &str,
        chat_id: &str,
        state: VibeChatLoadState,
    ) -> Result<(), VibeStoreError> {
        let key = load_state_key(user_id, chat_id);
        match state {
            VibeChatLoadState::NotLoaded => {
                self.conn
                    .execute("DELETE FROM core_meta_v1 WHERE k = ?1", params![key])
                    .map_err(|e| map_query_error(&e))?;
            }
            VibeChatLoadState::KnownEmpty => {
                self.meta_set_raw(&key, b"1")?;
            }
            VibeChatLoadState::Loaded => {
                self.meta_set_raw(&key, b"2")?;
            }
        }
        Ok(())
    }

    /// Read an opaque meta value by key.
    pub fn meta_get(&self, key: &str) -> Result<Option<Vec<u8>>, VibeStoreError> {
        self.conn
            .query_row(
                "SELECT v FROM core_meta_v1 WHERE k = ?1",
                params![key],
                |row| row.get(0),
            )
            .optional()
            .map_err(|e| map_query_error(&e))
    }

    /// Write an opaque meta value by key.
    pub fn meta_set(&self, key: &str, value: &[u8]) -> Result<(), VibeStoreError> {
        self.meta_set_raw(key, value)
    }

    /// Runs at most `batch_limit` rows, then returns. Call repeatedly until
    /// `done`. Resumes exactly where the last call stopped.
    ///
    /// Walks the legacy `messages` table **newest-first** via
    /// [`VibeLegacyStore::page_before`]. Each durable row is handed to `sealer`;
    /// returned opaque bytes are upserted into `core_messages_v1`. Transient ids
    /// and `sealer` returning `None` count as `skipped`.
    ///
    /// The resume cursor (in `core_meta_v1`) and the row writes commit in a
    /// single transaction. `batch_limit` is clamped to [`MAX_PAGE_LIMIT`]. A
    /// limit of `0` returns immediately with `done: false` and no work.
    pub fn backfill_batch(
        &self,
        legacy: &VibeLegacyStore,
        user_id: &str,
        chat_id: &str,
        sealer: &dyn VibeRowSealer,
        batch_limit: u32,
    ) -> Result<VibeBackfillProgress, VibeStoreError> {
        let batch_limit = clamp_limit(batch_limit);
        if batch_limit == 0 {
            return Ok(empty_progress(false));
        }

        let meta_key = backfill_cursor_key(user_id, chat_id);
        let resume = self.read_backfill_resume(&meta_key)?;
        if matches!(resume, BackfillResume::Done) {
            return Ok(empty_progress(true));
        }

        let before = match &resume {
            BackfillResume::Start => None,
            BackfillResume::Cursor(c) => Some(c.clone()),
            BackfillResume::Done => unreachable!(),
        };

        // Legacy read is outside the core txn. Crash before commit re-reads
        // the same page on resume; sealed upserts are idempotent.
        let legacy_rows = legacy.page_before(user_id, chat_id, before, batch_limit)?;
        if legacy_rows.is_empty() {
            self.meta_set_raw(&meta_key, &[BF_META_DONE])?;
            return Ok(empty_progress(true));
        }

        let (to_write, scanned, written, skipped) =
            seal_legacy_page(user_id, chat_id, sealer, &legacy_rows);

        // page_before is ascending; oldest row is the next-page frontier.
        let frontier = VibeStoreCursor {
            ts_ms: legacy_rows[0].ts_ms,
            message_id: legacy_rows[0].message_id.clone(),
        };
        let done = (legacy_rows.len() as u32) < batch_limit;
        let meta_value = if done {
            vec![BF_META_DONE]
        } else {
            encode_backfill_cursor(&frontier)
        };

        self.commit_backfill_batch(user_id, chat_id, &to_write, &meta_key, &meta_value)?;

        Ok(VibeBackfillProgress {
            scanned,
            written,
            skipped,
            done,
        })
    }

    /// Clears the resume cursor so the next call restarts from the newest row.
    pub fn reset_backfill_cursor(
        &self,
        user_id: &str,
        chat_id: &str,
    ) -> Result<(), VibeStoreError> {
        let key = backfill_cursor_key(user_id, chat_id);
        self.conn
            .execute("DELETE FROM core_meta_v1 WHERE k = ?1", params![key])
            .map_err(|e| map_query_error(&e))?;
        Ok(())
    }

    fn meta_set_raw(&self, key: &str, value: &[u8]) -> Result<(), VibeStoreError> {
        self.conn
            .execute(
                r"
                INSERT INTO core_meta_v1(k, v) VALUES (?1, ?2)
                ON CONFLICT(k) DO UPDATE SET v = excluded.v
                ",
                params![key, value],
            )
            .map_err(|e| map_query_error(&e))?;
        Ok(())
    }

    fn read_backfill_resume(&self, key: &str) -> Result<BackfillResume, VibeStoreError> {
        let value = self.meta_get(key)?;
        decode_backfill_resume(value.as_deref())
    }

    /// Upsert sealed rows and advance the backfill meta in one IMMEDIATE txn.
    fn commit_backfill_batch(
        &self,
        user_id: &str,
        chat_id: &str,
        rows: &[VibeSealedRow],
        meta_key: &str,
        meta_value: &[u8],
    ) -> Result<(), VibeStoreError> {
        let tx = Transaction::new_unchecked(&self.conn, TransactionBehavior::Immediate)
            .map_err(|e| map_query_error(&e))?;

        {
            let mut insert = tx
                .prepare(
                    r"
                    -- A tombstoned id is never re-admitted, on either write path.
                    --
                    -- This is the difference between a delete that holds and one that
                    -- has to be re-applied forever: the server keeps re-sending a
                    -- message the user deleted locally, and a plain upsert re-inserts
                    -- it on every history page — while the backfill walk would drag it
                    -- back out of the legacy table on the next rebuild. The tombstone is
                    -- the durable memory of the decision, so the refusal belongs in the
                    -- store rather than in a filter each caller has to remember.
                    INSERT INTO core_messages_v1(
                      user_id, chat_id, message_id, ts, order_key,
                      flags, sealed_body, seal_nonce
                    )
                    SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8
                    WHERE NOT EXISTS (
                      SELECT 1 FROM core_tombstones_v1
                      WHERE user_id = ?1 AND chat_id = ?2 AND message_id = ?3
                    )
                    ON CONFLICT(user_id, chat_id, message_id) DO UPDATE SET
                      ts = excluded.ts,
                      order_key = excluded.order_key,
                      flags = excluded.flags,
                      sealed_body = excluded.sealed_body,
                      seal_nonce = excluded.seal_nonce
                    ",
                )
                .map_err(|e| map_query_error(&e))?;

            for row in rows {
                if is_transient_id(&row.message_id) {
                    continue;
                }
                let order_key = pack_order_key(row.ts_ms, &row.message_id);
                insert
                    .execute(params![
                        user_id,
                        chat_id,
                        row.message_id,
                        row.ts_ms,
                        order_key,
                        row.flags,
                        row.sealed_body,
                        row.seal_nonce,
                    ])
                    .map_err(|e| map_query_error(&e))?;
            }
        }

        tx.execute(
            r"
            INSERT INTO core_meta_v1(k, v) VALUES (?1, ?2)
            ON CONFLICT(k) DO UPDATE SET v = excluded.v
            ",
            params![meta_key, meta_value],
        )
        .map_err(|e| map_query_error(&e))?;

        tx.commit().map_err(|e| map_query_error(&e))?;
        Ok(())
    }

    fn query_rows(
        &self,
        sql: &str,
        params: impl rusqlite::Params,
    ) -> Result<Vec<VibeSealedRow>, VibeStoreError> {
        let mut stmt = self.conn.prepare(sql).map_err(|e| map_query_error(&e))?;
        let mapped = stmt
            .query_map(params, |row| {
                Ok(VibeSealedRow {
                    message_id: row.get(0)?,
                    ts_ms: row.get(1)?,
                    flags: row.get(2)?,
                    sealed_body: row.get(3)?,
                    seal_nonce: row.get(4)?,
                })
            })
            .map_err(|e| map_query_error(&e))?;

        let mut out = Vec::new();
        for row in mapped {
            out.push(row.map_err(|e| map_query_error(&e))?);
        }
        Ok(out)
    }
}

/// Pack `(ts, message_id)` so byte-wise order matches `ts ASC, message_id ASC`.
///
/// Layout: big-endian `i64` with the sign bit flipped, then `0x00`, then the
/// UTF-8 id bytes. Sign-bit flip maps the full signed range into unsigned
/// lexicographic order (negatives before zero before positives).
pub(crate) fn pack_order_key(ts_ms: i64, message_id: &str) -> Vec<u8> {
    let ordered = (ts_ms as u64) ^ 0x8000_0000_0000_0000;
    let mut key = Vec::with_capacity(8 + 1 + message_id.len());
    key.extend_from_slice(&ordered.to_be_bytes());
    key.push(0x00);
    key.extend_from_slice(message_id.as_bytes());
    key
}

/// Transient ids are never durable: live stream, LAN, and bridge prefixes.
fn is_transient_id(message_id: &str) -> bool {
    message_id.starts_with("stream-")
        || message_id.starts_with("lan-")
        || message_id.starts_with("bridge-")
}

fn load_state_key(user_id: &str, chat_id: &str) -> String {
    // Unit separator avoids collision when user/chat ids contain ordinary
    // punctuation. Prefix keeps load-state keys out of the caller's meta space.
    format!("ls\u{1f}{user_id}\u{1f}{chat_id}")
}

fn backfill_cursor_key(user_id: &str, chat_id: &str) -> String {
    // Distinct prefix from load-state (`ls`) and the caller's free meta space.
    format!("bf\u{1f}{user_id}\u{1f}{chat_id}")
}

/// In-memory decode of the persisted backfill resume marker.
enum BackfillResume {
    /// No meta row — start at the newest legacy page.
    Start,
    /// Resume strictly older than this inclusive frontier.
    Cursor(VibeStoreCursor),
    /// Prior batch already exhausted the chat.
    Done,
}

fn empty_progress(done: bool) -> VibeBackfillProgress {
    VibeBackfillProgress {
        scanned: 0,
        written: 0,
        skipped: 0,
        done,
    }
}

/// Hand each durable legacy row to the sealer. Returns sealed rows plus counts.
///
/// Payload bytes are only passed through to `sealer` — never inspected here.
fn seal_legacy_page(
    user_id: &str,
    chat_id: &str,
    sealer: &dyn VibeRowSealer,
    legacy_rows: &[VibeStoredRow],
) -> (Vec<VibeSealedRow>, u64, u64, u64) {
    let mut to_write = Vec::new();
    let mut scanned = 0u64;
    let mut written = 0u64;
    let mut skipped = 0u64;

    for row in legacy_rows {
        scanned += 1;
        if is_transient_id(&row.message_id) {
            skipped += 1;
            continue;
        }
        match sealer.seal(user_id, chat_id, &row.message_id, &row.payload) {
            Some((sealed_body, seal_nonce)) => {
                to_write.push(VibeSealedRow {
                    message_id: row.message_id.clone(),
                    ts_ms: row.ts_ms,
                    flags: 0,
                    sealed_body,
                    seal_nonce,
                });
                written += 1;
            }
            None => {
                skipped += 1;
            }
        }
    }

    (to_write, scanned, written, skipped)
}

fn encode_backfill_cursor(cursor: &VibeStoreCursor) -> Vec<u8> {
    let mut v = Vec::with_capacity(1 + 8 + cursor.message_id.len());
    v.push(BF_META_CURSOR);
    v.extend_from_slice(&cursor.ts_ms.to_be_bytes());
    v.extend_from_slice(cursor.message_id.as_bytes());
    v
}

fn decode_backfill_resume(value: Option<&[u8]>) -> Result<BackfillResume, VibeStoreError> {
    match value {
        None | Some([]) => Ok(BackfillResume::Start),
        Some([BF_META_DONE]) => Ok(BackfillResume::Done),
        Some([BF_META_CURSOR, rest @ ..]) if rest.len() >= 8 => {
            let mut ts_bytes = [0u8; 8];
            ts_bytes.copy_from_slice(&rest[..8]);
            let ts_ms = i64::from_be_bytes(ts_bytes);
            let message_id = std::str::from_utf8(&rest[8..])
                .map_err(|_| VibeStoreError::QueryFailed)?
                .to_string();
            Ok(BackfillResume::Cursor(VibeStoreCursor {
                ts_ms,
                message_id,
            }))
        }
        // Corrupt / unknown encoding is a shape failure — never embed bytes.
        _ => Err(VibeStoreError::QueryFailed),
    }
}

fn clamp_limit(limit: u32) -> u32 {
    limit.min(MAX_PAGE_LIMIT)
}

#[cfg(test)]
mod order_key_unit_tests {
    use super::pack_order_key;

    #[test]
    fn order_key_byte_order_matches_signed_ts_and_id() {
        // Negative, zero, large positive, and same-ts id pairs.
        let mut samples: Vec<(i64, &str)> = vec![
            (i64::MIN, "a"),
            (-1, "z"),
            (-1, "a"),
            (0, "m"),
            (1, "a"),
            (i64::MAX, "a"),
            (1_700_000_000_000, "b"),
            (1_700_000_000_000, "a"),
            (i64::MIN + 1, "x"),
        ];

        samples.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(b.1)));

        let keys: Vec<Vec<u8>> = samples
            .iter()
            .map(|(ts, id)| pack_order_key(*ts, id))
            .collect();

        for w in keys.windows(2) {
            assert!(
                w[0] < w[1],
                "order_key not strictly increasing for sorted (ts,id) pairs"
            );
        }
    }

    #[test]
    fn order_key_same_ts_sorts_by_id_bytes() {
        let ka = pack_order_key(100, "a");
        let kb = pack_order_key(100, "b");
        let kc = pack_order_key(100, "c");
        assert!(ka < kb && kb < kc);
    }

    #[test]
    fn transient_prefix_detection() {
        assert!(super::is_transient_id("stream-1"));
        assert!(super::is_transient_id("lan-xyz"));
        assert!(super::is_transient_id("bridge-abc"));
        assert!(!super::is_transient_id("msg-1"));
        assert!(!super::is_transient_id("stream"));
        assert!(!super::is_transient_id("lan"));
        assert!(!super::is_transient_id("bridge"));
    }
}
